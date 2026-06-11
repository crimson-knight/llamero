// C ABI bridge between Crystal (src/native/mlx_bridge.cr) and the MLX Swift
// runtime. The contract:
//
// - Handles are opaque positive Int64 tokens kept in BridgeRegistry.
// - Requests/configs cross as JSON strings (snake_case keys).
// - Results stream back as JSON event frames through a C callback that is
//   ALWAYS invoked on the calling thread (Crystal's GC cannot tolerate
//   callbacks from foreign threads). Async MLX work runs in a detached Task
//   that feeds an EventSink; the calling thread drains the sink until the
//   task finishes.
// - Errors surface both as an `error` event frame and a nonzero status.

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import Tokenizers

public typealias LlameroEventCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

// MARK: - JSON payloads from Crystal

struct RuntimeConfig: Codable {
    var modelId: String
    var modelPath: String?
    var fallbackModelId: String?
    var cacheLimitBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case modelPath = "model_path"
        case fallbackModelId = "fallback_model_id"
        case cacheLimitBytes = "cache_limit_bytes"
    }
}

struct LoadRequest: Codable {
    var modelPath: String?

    enum CodingKeys: String, CodingKey {
        case modelPath = "model_path"
    }
}

struct RequestMessage: Codable {
    var role: String
    var content: String
}

struct GenerateRequest: Codable {
    var messages: [RequestMessage]
    var temperature: Float?
    var maxTokens: Int?
    var structured: Bool?

    enum CodingKeys: String, CodingKey {
        case messages, temperature, structured
        case maxTokens = "max_tokens"
    }
}

struct TrainRequest: Codable {
    var name: String
    var dataDir: String
    var outputDir: String
    var rank: Int
    var scale: Float
    var numLayers: Int
    var fineTuneType: String
    var iterations: Int
    var batchSize: Int
    var learningRate: Float
    var stepsPerReport: Int
    var stepsPerEval: Int
    var validationBatches: Int

    enum CodingKeys: String, CodingKey {
        case name
        case dataDir = "data_dir"
        case outputDir = "output_dir"
        case rank, scale, iterations
        case numLayers = "num_layers"
        case fineTuneType = "fine_tune_type"
        case batchSize = "batch_size"
        case learningRate = "learning_rate"
        case stepsPerReport = "steps_per_report"
        case stepsPerEval = "steps_per_eval"
        case validationBatches = "validation_batches"
    }
}

struct StackSlot: Codable {
    var name: String
    var scale: Double
    var path: String
    var checksum: String?
}

struct StackPayload: Codable {
    var stackId: String
    var mode: String
    var slots: [StackSlot]

    enum CodingKeys: String, CodingKey {
        case stackId = "stack_id"
        case mode, slots
    }
}

struct BridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Handle registry

final class RuntimeBox: @unchecked Sendable {
    let config: RuntimeConfig
    init(config: RuntimeConfig) { self.config = config }
}

final class SessionBox: @unchecked Sendable {
    let handle: Int64
    let runtime: RuntimeBox
    var container: ModelContainer?
    var loaded = false
    var activeAdapters: [(name: String, adapter: any ModelAdapter)] = []
    var adapterStackId = "base"

    init(handle: Int64, runtime: RuntimeBox) {
        self.handle = handle
        self.runtime = runtime
    }

    var modelId: String { runtime.config.modelId }
}

final class BridgeRegistry: @unchecked Sendable {
    static let shared = BridgeRegistry()
    private let lock = NSLock()
    private var nextHandle: Int64 = 1
    private var runtimes: [Int64: RuntimeBox] = [:]
    private var sessions: [Int64: SessionBox] = [:]

    func addRuntime(_ runtime: RuntimeBox) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        runtimes[handle] = runtime
        return handle
    }

    func runtime(_ handle: Int64) -> RuntimeBox? {
        lock.lock(); defer { lock.unlock() }
        return runtimes[handle]
    }

    func removeRuntime(_ handle: Int64) {
        lock.lock(); defer { lock.unlock() }
        runtimes[handle] = nil
    }

    func addSession(runtime: RuntimeBox) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        sessions[handle] = SessionBox(handle: handle, runtime: runtime)
        return handle
    }

    func session(_ handle: Int64) -> SessionBox? {
        lock.lock(); defer { lock.unlock() }
        return sessions[handle]
    }

    func removeSession(_ handle: Int64) {
        lock.lock(); defer { lock.unlock() }
        sessions[handle] = nil
    }
}

// MARK: - Event sink (async producer, calling-thread consumer)

final class EventSink: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [String] = []
    private var finished = false
    private var status: Int32 = 0

    private let sessionId: String
    private let modelId: String
    var adapterStackId: String

    private static let timestampFormatter = ISO8601DateFormatter()

    init(sessionId: String, modelId: String, adapterStackId: String) {
        self.sessionId = sessionId
        self.modelId = modelId
        self.adapterStackId = adapterStackId
    }

    func emit(_ payload: [String: Any]) {
        var frame = payload
        frame["session_id"] = sessionId
        frame["model_id"] = modelId
        frame["adapter_stack_id"] = adapterStackId
        frame["created_at"] = Self.timestampFormatter.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
            let json = String(data: data, encoding: .utf8)
        else { return }

        condition.lock()
        pending.append(json)
        condition.signal()
        condition.unlock()
    }

    func fail(message: String, code: String, recoverable: Bool, baseModelLoaded: Bool) {
        emit([
            "event": "error",
            "message": message,
            "code": code,
            "recoverable": recoverable,
            "base_model_loaded": baseModelLoaded,
        ])
        finish(status: 1)
    }

    func finish(status: Int32 = 0) {
        condition.lock()
        self.status = status
        finished = true
        condition.signal()
        condition.unlock()
    }

    // Runs on the FFI calling thread: delivers frames to the callback until
    // the producing task finishes and the queue is empty.
    func drain(callback: LlameroEventCallback?, userData: UnsafeMutableRawPointer?) -> Int32 {
        while true {
            condition.lock()
            while pending.isEmpty && !finished {
                condition.wait()
            }
            let batch = pending
            pending.removeAll()
            let done = finished && pending.isEmpty
            let finalStatus = status
            condition.unlock()

            if let callback {
                for json in batch {
                    json.withCString { callback($0, userData) }
                }
            }
            if done {
                return finalStatus
            }
        }
    }
}

// MARK: - C ABI entry points

@_cdecl("llamero_mlx_runtime_create")
public func llamero_mlx_runtime_create(_ configJson: UnsafePointer<CChar>?) -> Int64 {
    guard let configJson,
        let data = String(cString: configJson).data(using: .utf8),
        let config = try? JSONDecoder().decode(RuntimeConfig.self, from: data)
    else { return -1 }

    if let limit = config.cacheLimitBytes {
        MLX.GPU.set(cacheLimit: Int(limit))
    }
    return BridgeRegistry.shared.addRuntime(RuntimeBox(config: config))
}

@_cdecl("llamero_mlx_runtime_free")
public func llamero_mlx_runtime_free(_ handle: Int64) {
    BridgeRegistry.shared.removeRuntime(handle)
}

@_cdecl("llamero_mlx_session_create")
public func llamero_mlx_session_create(_ runtimeHandle: Int64) -> Int64 {
    guard let runtime = BridgeRegistry.shared.runtime(runtimeHandle) else { return -1 }
    return BridgeRegistry.shared.addSession(runtime: runtime)
}

@_cdecl("llamero_mlx_session_free")
public func llamero_mlx_session_free(_ handle: Int64) {
    BridgeRegistry.shared.removeSession(handle)
}

@_cdecl("llamero_mlx_session_load_model")
public func llamero_mlx_session_load_model(
    _ handle: Int64,
    _ requestJson: UnsafePointer<CChar>?,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let session = BridgeRegistry.shared.session(handle) else { return 2 }
    let request: LoadRequest
    if let requestJson,
        let data = String(cString: requestJson).data(using: .utf8),
        let decoded = try? JSONDecoder().decode(LoadRequest.self, from: data)
    {
        request = decoded
    } else {
        request = LoadRequest(modelPath: nil)
    }

    let sink = EventSink(
        sessionId: "mlx-session-\(handle)",
        modelId: session.modelId,
        adapterStackId: session.adapterStackId
    )

    Task.detached {
        do {
            sink.emit(["event": "model_load_started"])
            let start = Date()

            // The Crystal side downloads models and always hands us a local
            // directory. The HuggingFace hub fallback below requires the host
            // process to service the main dispatch queue (the downloader hops
            // through the main actor), so it only works inside Swift apps -
            // never under a Crystal/C host with a blocked main thread.
            let configuration: ModelConfiguration
            if let path = request.modelPath ?? session.runtime.config.modelPath {
                configuration = ModelConfiguration(directory: URL(fileURLWithPath: path))
            } else {
                configuration = ModelConfiguration(id: session.runtime.config.modelId)
            }

            let wasLoaded = session.loaded
            let container = try await #huggingFaceLoadModelContainer(configuration: configuration)

            session.container = container
            session.loaded = true
            session.activeAdapters = []

            let elapsedMs = Date().timeIntervalSince(start) * 1000
            sink.emit([
                "event": "model_loaded",
                "load_time_ms": elapsedMs,
                "memory_bytes": MLX.GPU.activeMemory,
                "reloaded": wasLoaded,
            ])
            sink.finish()
        } catch {
            sink.fail(
                message: "Model load failed: \(error)",
                code: "model_load_failed",
                recoverable: true,
                baseModelLoaded: session.loaded
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}

@_cdecl("llamero_mlx_session_activate_adapters")
public func llamero_mlx_session_activate_adapters(
    _ handle: Int64,
    _ stackJson: UnsafePointer<CChar>?,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let session = BridgeRegistry.shared.session(handle) else { return 2 }
    guard let stackJson,
        let data = String(cString: stackJson).data(using: .utf8),
        let payload = try? JSONDecoder().decode(StackPayload.self, from: data)
    else { return 3 }

    let sink = EventSink(
        sessionId: "mlx-session-\(handle)",
        modelId: session.modelId,
        adapterStackId: session.adapterStackId
    )

    Task.detached {
        guard let container = session.container, session.loaded else {
            sink.fail(
                message: "Cannot activate adapters before the model is loaded",
                code: "adapter_activation_failed",
                recoverable: true,
                baseModelLoaded: false
            )
            return
        }

        do {
            // v1 scope: stock single-adapter hot swap. Stacking and per-slot
            // scale overrides need a custom runtime path and are rejected
            // honestly instead of silently approximated.
            if payload.slots.count > 1 {
                throw BridgeError(message: "Multi-adapter stacks are not yet supported by the MLX bridge (got \(payload.slots.count) adapters)")
            }
            if let slot = payload.slots.first, abs(slot.scale - 1.0) > 1e-9 {
                throw BridgeError(message: "Per-slot scale overrides are not yet supported by the MLX bridge (adapter \(slot.name) has scale \(slot.scale)); the adapter's own trained scale from adapter_config.json is used")
            }

            try await container.perform { context in
                for (_, adapter) in session.activeAdapters.reversed() {
                    adapter.unload(from: context.model)
                }
                session.activeAdapters = []

                if let slot = payload.slots.first {
                    let adapter = try LoRAContainer.from(directory: URL(fileURLWithPath: slot.path))
                    try adapter.load(into: context.model)
                    session.activeAdapters = [(slot.name, adapter)]
                }
            }

            session.adapterStackId = payload.stackId
            sink.adapterStackId = payload.stackId
            sink.emit([
                "event": "adapter_activated",
                "adapter_names": payload.slots.map(\.name),
                "base_model_reloaded": false,
            ])
            sink.finish()
        } catch {
            sink.fail(
                message: "Adapter activation failed: \(error)",
                code: "adapter_activation_failed",
                recoverable: true,
                baseModelLoaded: session.loaded
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}

@_cdecl("llamero_mlx_session_train_adapter")
public func llamero_mlx_session_train_adapter(
    _ handle: Int64,
    _ requestJson: UnsafePointer<CChar>?,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let session = BridgeRegistry.shared.session(handle) else { return 2 }
    guard let requestJson,
        let data = String(cString: requestJson).data(using: .utf8),
        let request = try? JSONDecoder().decode(TrainRequest.self, from: data)
    else { return 3 }

    let sink = EventSink(
        sessionId: "mlx-session-\(handle)",
        modelId: session.modelId,
        adapterStackId: session.adapterStackId
    )

    Task.detached {
        guard let container = session.container, session.loaded else {
            sink.fail(
                message: "Cannot train an adapter before the model is loaded",
                code: "adapter_training_failed",
                recoverable: true,
                baseModelLoaded: false
            )
            return
        }
        guard session.activeAdapters.isEmpty else {
            sink.fail(
                message: "Deactivate adapters before training (training composes with active adapter layers)",
                code: "adapter_training_failed",
                recoverable: true,
                baseModelLoaded: true
            )
            return
        }

        do {
            let dataURL = URL(fileURLWithPath: request.dataDir)
            let train = try loadLoRAData(directory: dataURL, name: "train")
            let valid = (try? loadLoRAData(directory: dataURL, name: "valid")) ?? []
            if train.isEmpty {
                throw BridgeError(message: "Training dataset at \(request.dataDir) is empty")
            }

            let configuration = LoRAConfiguration(
                numLayers: request.numLayers,
                fineTuneType: request.fineTuneType == "dora" ? .dora : .lora,
                loraParameters: .init(rank: request.rank, scale: request.scale)
            )

            // Validation needs data; without any, push evals past the end.
            let stepsPerEval = valid.isEmpty ? request.iterations + 1 : request.stepsPerEval
            let parameters = LoRATrain.Parameters(
                batchSize: request.batchSize,
                iterations: request.iterations,
                stepsPerReport: request.stepsPerReport,
                stepsPerEval: stepsPerEval,
                validationBatches: request.validationBatches,
                saveEvery: Int.max,
                adapterURL: nil
            )

            let start = Date()

            let result: (finalLoss: Double, validationLoss: Double?) = try await container.perform { context in
                // Applies (Q)LoRA layers in place and freezes the base
                // weights. On quantized models the replacement layers are
                // QLoRALinear - QLoRA happens automatically.
                let adapter = try LoRAContainer.from(model: context.model, configuration: configuration)

                var lastLoss: Double = 0
                var lastValidation: Double? = nil

                do {
                    try LoRATrain.train(
                        model: context.model,
                        train: train,
                        validate: valid,
                        optimizer: Adam(learningRate: request.learningRate),
                        tokenizer: context.tokenizer,
                        parameters: parameters
                    ) { progress in
                        switch progress {
                        case .train(let iteration, let loss, let iterationsPerSecond, let tokensPerSecond):
                            lastLoss = Double(loss)
                            sink.emit([
                                "event": "training_progress",
                                "adapter_name": request.name,
                                "iteration": iteration,
                                "total_iterations": request.iterations,
                                "loss": Double(loss),
                                "iterations_per_second": iterationsPerSecond,
                                "tokens_per_second": tokensPerSecond,
                            ])
                        case .validation(let iteration, let validationLoss, _):
                            lastValidation = Double(validationLoss)
                            sink.emit([
                                "event": "training_validation",
                                "adapter_name": request.name,
                                "iteration": iteration,
                                "validation_loss": Double(validationLoss),
                            ])
                        case .save:
                            break
                        }
                        return .more
                    }

                    // Final score against the validation set.
                    if !valid.isEmpty {
                        let finalValidation = try LoRATrain.evaluate(
                            model: context.model,
                            dataset: valid,
                            tokenizer: context.tokenizer,
                            batchSize: request.batchSize,
                            batchCount: 0
                        )
                        lastValidation = Double(finalValidation)
                        sink.emit([
                            "event": "training_validation",
                            "adapter_name": request.name,
                            "iteration": request.iterations,
                            "validation_loss": Double(finalValidation),
                        ])
                    }

                    // Persist in the mlx_lm adapter layout that
                    // LoRAContainer.from(directory:) round-trips.
                    let outputURL = URL(fileURLWithPath: request.outputDir)
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    let weights = Dictionary(uniqueKeysWithValues: context.model.trainableParameters().flattened())
                    try MLX.save(arrays: weights, url: outputURL.appending(component: "adapters.safetensors"))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    try encoder.encode(configuration).write(to: outputURL.appending(component: "adapter_config.json"))

                    // Restore the resident model's original layers; the
                    // trained adapter only applies when explicitly activated.
                    adapter.unload(from: context.model)
                } catch {
                    adapter.unload(from: context.model)
                    throw error
                }

                return (lastLoss, lastValidation)
            }

            var completed: [String: Any] = [
                "event": "training_completed",
                "adapter_name": request.name,
                "adapter_path": request.outputDir,
                "iterations": request.iterations,
                "final_loss": result.finalLoss,
                "total_time_ms": Date().timeIntervalSince(start) * 1000,
            ]
            if let validation = result.validationLoss {
                completed["final_validation_loss"] = validation
            }
            sink.emit(completed)
            sink.finish()
        } catch {
            sink.fail(
                message: "Adapter training failed: \(error)",
                code: "adapter_training_failed",
                recoverable: true,
                baseModelLoaded: session.loaded
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}

@_cdecl("llamero_mlx_session_generate")
public func llamero_mlx_session_generate(
    _ handle: Int64,
    _ requestJson: UnsafePointer<CChar>?,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let session = BridgeRegistry.shared.session(handle) else { return 2 }
    guard let requestJson,
        let data = String(cString: requestJson).data(using: .utf8),
        let request = try? JSONDecoder().decode(GenerateRequest.self, from: data)
    else { return 3 }

    let sink = EventSink(
        sessionId: "mlx-session-\(handle)",
        modelId: session.modelId,
        adapterStackId: session.adapterStackId
    )

    Task.detached {
        guard let container = session.container, session.loaded else {
            sink.fail(
                message: "Cannot generate before the model is loaded",
                code: "generation_failed",
                recoverable: true,
                baseModelLoaded: false
            )
            return
        }

        do {
            let chat: [Chat.Message] = request.messages.map { message in
                switch message.role {
                case "system": return .system(message.content)
                case "assistant": return .assistant(message.content)
                default: return .user(message.content)
                }
            }

            var parameters = GenerateParameters()
            if let temperature = request.temperature { parameters.temperature = temperature }
            if let maxTokens = request.maxTokens { parameters.maxTokens = maxTokens }

            let deltaEvent = (request.structured ?? false) ? "structured_json_delta" : "token_delta"

            try await container.perform { context in
                let input = try await context.processor.prepare(input: UserInput(chat: chat))
                let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)

                for await generation in stream {
                    switch generation {
                    case .chunk(let text):
                        sink.emit(["event": deltaEvent, "text": text])
                    case .info(let info):
                        sink.emit([
                            "event": "generation_completed",
                            "finish_reason": "\(info.stopReason)",
                            "input_tokens": info.promptTokenCount,
                            "output_tokens": info.generationTokenCount,
                            "tokens_per_second": info.tokensPerSecond,
                            "time_to_first_token_ms": info.promptTime * 1000,
                            "total_time_ms": (info.promptTime + info.generateTime) * 1000,
                        ])
                    default:
                        break
                    }
                }
            }
            sink.finish()
        } catch {
            sink.fail(
                message: "Generation failed: \(error)",
                code: "generation_failed",
                recoverable: true,
                baseModelLoaded: session.loaded
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}
