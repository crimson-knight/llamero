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

// Macro-free model loading. Replicates exactly what the MLXHuggingFace
// `#huggingFaceLoadModelContainer` macro expands to (DownloaderMacro +
// TokenizerLoaderMacro + TokenizerAdaptorMacro). We inline it because that
// macro plugin crashes at expansion time under the current Swift toolchain
// (`failed to receive result from plugin`). The bridge only ever loads LOCAL
// directories — Crystal owns model downloads — so the Downloader is a stub that
// is never invoked; the loader reads the tokenizer from the local model folder.

private struct LocalOnlyDownloader: MLXLMCommon.Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Foundation.Progress) -> Void
    ) async throws -> URL {
        throw NSError(
            domain: "LlameroMLXBridge", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "remote model download is not supported in the bridge; Crystal owns downloads (pass a local model_path)"])
    }
}

private struct LlameroTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private struct LlameroTokenizerLoader: MLXLMCommon.TokenizerLoader {
    init() {}
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return LlameroTokenizerBridge(upstream)
    }
}

public typealias LlameroEventCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

// Reward callback for bridge-driven RL: given (prompt, completion), returns a
// scalar reward. Invoked on the FFI calling (Crystal) thread via drainRL.
public typealias LlameroRewardCallback = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Double

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
    // Training method: nil/"sft" (default), "dpo" (preference), or
    // "weighted"/"grpo" (advantage-weighted policy update). Optional for
    // backward compat with callers that predate RL.
    var method: String?
    var dpoBeta: Float?
    var klBeta: Float?

    enum CodingKeys: String, CodingKey {
        case name
        case dataDir = "data_dir"
        case outputDir = "output_dir"
        case rank, scale, iterations, method
        case numLayers = "num_layers"
        case fineTuneType = "fine_tune_type"
        case batchSize = "batch_size"
        case learningRate = "learning_rate"
        case stepsPerReport = "steps_per_report"
        case stepsPerEval = "steps_per_eval"
        case validationBatches = "validation_batches"
        case dpoBeta = "dpo_beta"
        case klBeta = "kl_beta"
    }
}

// Bridge-driven GRPO loop request: the bridge samples completions for each
// prompt, asks Crystal for rewards, computes group-relative advantages, and
// runs the KL-anchored weighted update — for `rounds` rounds.
struct GRPORequest: Codable {
    var name: String
    var outputDir: String
    var rank: Int
    var scale: Float
    var numLayers: Int
    var prompts: [String]
    var rounds: Int
    var samples: Int
    var temperature: Float
    var maxTokens: Int
    var iterations: Int
    var learningRate: Float
    var klBeta: Float

    enum CodingKeys: String, CodingKey {
        case name, prompts, rounds, samples, temperature, iterations, rank, scale
        case outputDir = "output_dir"
        case numLayers = "num_layers"
        case maxTokens = "max_tokens"
        case learningRate = "learning_rate"
        case klBeta = "kl_beta"
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
    // When true, fuse the adapter delta into the (re-quantized) base weights
    // instead of installing live LoRA layers. Optional for backward compat with
    // callers that predate the flag.
    var fuse: Bool?

    enum CodingKeys: String, CodingKey {
        case stackId = "stack_id"
        case mode, slots, fuse
    }
}

struct BridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// Local directory loads bypass mlx-swift-lm's model registry entries, so keep
// the chat-template stop markers that those entries normally provide.
private let localEOSTokenCandidates: Set<String> = [
    "<end_of_turn>",
    "<|eot_id|>",
    "<|im_end|>",
    "<|end|>",
    "<turn|>",
]

private func inferredExtraEOSTokens(modelDirectory: URL) -> Set<String> {
    let fileNames = ["tokenizer_config.json", "tokenizer.json", "chat_template.jinja", "chat_template.json"]
    var text = ""
    for fileName in fileNames {
        let url = modelDirectory.appending(component: fileName)
        if let contents = try? String(contentsOf: url) {
            text += contents
        }
    }
    return Set(localEOSTokenCandidates.filter { text.contains($0) })
}

final class SpecialTokenAwareTrainingTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any MLXLMCommon.Tokenizer
    private let specialTokenIds: [(token: String, id: Int)]
    private let addedSpecialTokenWrapper: (prefix: [Int], suffix: [Int])?

    init(_ upstream: any MLXLMCommon.Tokenizer) {
        self.upstream = upstream

        var candidates = localEOSTokenCandidates
        if let bos = upstream.bosToken { candidates.insert(bos) }
        if let eos = upstream.eosToken { candidates.insert(eos) }
        if let unknown = upstream.unknownToken { candidates.insert(unknown) }

        self.specialTokenIds = candidates.compactMap { token in
            upstream.convertTokenToId(token).map { (token: token, id: $0) }
        }.sorted { $0.token.count > $1.token.count }

        let sentinel = "llamero"
        let withoutSpecial = upstream.encode(text: sentinel, addSpecialTokens: false)
        let withSpecial = upstream.encode(text: sentinel, addSpecialTokens: true)
        if let range = Self.findSubsequence(withoutSpecial, in: withSpecial) {
            self.addedSpecialTokenWrapper = (
                prefix: Array(withSpecial[..<range.lowerBound]),
                suffix: Array(withSpecial[range.upperBound...])
            )
        } else {
            self.addedSpecialTokenWrapper = nil
        }
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        let native = upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        let presentTokens = specialTokenIds.filter { text.contains($0.token) }
        guard !presentTokens.isEmpty else { return native }

        let nativeCounts = Dictionary(grouping: native, by: { $0 }).mapValues(\.count)
        let nativeCovered = presentTokens.allSatisfy { token, id in
            (nativeCounts[id] ?? 0) >= Self.countOccurrences(of: token, in: text)
        }
        if nativeCovered {
            return native
        }

        let spliced = encodeBySplicingSpecialTokens(text)
        if addSpecialTokens, let wrapper = addedSpecialTokenWrapper {
            return wrapper.prefix + spliced + wrapper.suffix
        }
        return spliced
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext
        )
    }

    private func encodeBySplicingSpecialTokens(_ text: String) -> [Int] {
        var ids: [Int] = []
        var buffer = ""
        var index = text.startIndex

        func flushBuffer() {
            if !buffer.isEmpty {
                ids += upstream.encode(text: buffer, addSpecialTokens: false)
                buffer = ""
            }
        }

        while index < text.endIndex {
            let suffix = text[index...]
            if let match = specialTokenIds.first(where: { suffix.hasPrefix($0.token) }) {
                flushBuffer()
                ids.append(match.id)
                index = text.index(index, offsetBy: match.token.count)
            } else {
                buffer.append(text[index])
                index = text.index(after: index)
            }
        }
        flushBuffer()
        return ids
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private static func findSubsequence(_ needle: [Int], in haystack: [Int]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            if Array(haystack[start..<end]) == needle {
                return start..<end
            }
        }
        return nil
    }
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

    // ---- Reward request/response channel (bridge-driven RL) ----
    // The work task posts a (prompt, completion) and blocks; drainRL (on the
    // Crystal calling thread) invokes the reward callback and replies. This
    // keeps Crystal callbacks on the Crystal thread, like event delivery.
    private var rewardPending = false
    private var rewardAnswered = false
    private var rewardPrompt = ""
    private var rewardCompletion = ""
    private var rewardResult: Double = 0

    func askReward(prompt: String, completion: String) -> Double {
        condition.lock()
        rewardPrompt = prompt
        rewardCompletion = completion
        rewardPending = true
        rewardAnswered = false
        condition.signal()
        while !rewardAnswered {
            condition.wait()
        }
        let r = rewardResult
        condition.unlock()
        return r
    }

    func drainRL(
        eventCallback: LlameroEventCallback?, eventUserData: UnsafeMutableRawPointer?,
        rewardCallback: LlameroRewardCallback?, rewardUserData: UnsafeMutableRawPointer?
    ) -> Int32 {
        while true {
            condition.lock()
            while pending.isEmpty && !finished && !rewardPending {
                condition.wait()
            }
            if rewardPending {
                let p = rewardPrompt
                let c = rewardCompletion
                condition.unlock()
                let r = p.withCString { pc in c.withCString { cc in
                    rewardCallback?(pc, cc, rewardUserData) ?? 0
                }}
                condition.lock()
                rewardResult = r
                rewardPending = false
                rewardAnswered = true
                condition.signal()
                condition.unlock()
                continue
            }
            let batch = pending
            pending.removeAll()
            let done = finished && pending.isEmpty
            let finalStatus = status
            condition.unlock()

            if let eventCallback {
                for json in batch {
                    json.withCString { eventCallback($0, eventUserData) }
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
                let modelDirectory = URL(fileURLWithPath: path)
                configuration = ModelConfiguration(
                    directory: modelDirectory,
                    extraEOSTokens: inferredExtraEOSTokens(modelDirectory: modelDirectory)
                )
            } else {
                configuration = ModelConfiguration(id: session.runtime.config.modelId)
            }

            let wasLoaded = session.loaded
            let container = try await loadModelContainer(
                from: LocalOnlyDownloader(),
                using: LlameroTokenizerLoader(),
                configuration: configuration,
                progressHandler: { _ in })

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

            // Fuse the adapter into the (re-quantized) base weights instead of
            // installing live LoRA layers when requested. QLoRALinear.fused()
            // dequantizes -> adds scale*(B@A) -> RE-QUANTIZES, so the model stays
            // 4-bit and generation runs with zero extra LoRA ops at full base
            // throughput. Trade-off: the resident base is mutated (and slightly
            // re-quantized), so deactivation/hot-swap then needs a base reload
            // rather than a cheap unload — the Crystal side handles that by
            // reloading on the next activation. Driven by the per-call `fuse`
            // flag; LLAMERO_FUSE_ADAPTERS stays as a global override.
            let shouldFuse = (payload.fuse ?? false)
                || ProcessInfo.processInfo.environment["LLAMERO_FUSE_ADAPTERS"] != nil
            let didFuse = shouldFuse && !payload.slots.isEmpty

            try await container.perform { context in
                for (_, adapter) in session.activeAdapters.reversed() {
                    adapter.unload(from: context.model)
                }
                session.activeAdapters = []

                if let slot = payload.slots.first {
                    let adapter = try LoRAContainer.from(directory: URL(fileURLWithPath: slot.path))
                    if shouldFuse {
                        try adapter.fuse(with: context.model)
                    } else {
                        try adapter.load(into: context.model)
                    }
                    session.activeAdapters = [(slot.name, adapter)]
                }
            }

            session.adapterStackId = payload.stackId
            sink.adapterStackId = payload.stackId
            sink.emit([
                "event": "adapter_activated",
                "adapter_names": payload.slots.map(\.name),
                "base_model_reloaded": false,
                "fused": didFuse,
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
            let method = request.method ?? "sft"
            // SFT reads {"text": …}; DPO/weighted read their own row formats
            // inside RLTrain, so only load the SFT corpus here.
            var train: [String] = []
            var valid: [String] = []
            if method == "sft" {
                train = try loadLoRAData(directory: dataURL, name: "train")
                valid = (try? loadLoRAData(directory: dataURL, name: "valid")) ?? []
                if train.isEmpty {
                    throw BridgeError(message: "Training dataset at \(request.dataDir) is empty")
                }
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
                let trainingTokenizer = SpecialTokenAwareTrainingTokenizer(context.tokenizer)
                var lastLoss: Double = 0
                var lastValidation: Double? = nil

                // DPO/GRPO references are the FROZEN base — measure before LoRA install.
                var dpoPrefs: [RLTrain.Pref] = []
                var weightedSamples: [RLTrain.WeightedSample] = []
                if method == "dpo" {
                    dpoPrefs = try RLTrain.loadPrefs(dataDir: dataURL, tokenizer: trainingTokenizer)
                    RLTrain.cacheReferences(model: context.model, prefs: &dpoPrefs)
                } else if method == "weighted" || method == "grpo" {
                    weightedSamples = try RLTrain.loadWeighted(dataDir: dataURL, tokenizer: trainingTokenizer)
                    RLTrain.cacheWeightedReferences(model: context.model, samples: &weightedSamples)
                }

                // Applies (Q)LoRA layers in place and freezes the base weights.
                // On quantized models the replacement layers are QLoRALinear.
                let adapter = try LoRAContainer.from(model: context.model, configuration: configuration)

                do {
                    switch method {
                    case "dpo":
                        lastLoss = RLTrain.runDPO(
                            model: context.model, prefs: dpoPrefs,
                            iterations: request.iterations, learningRate: request.learningRate,
                            beta: request.dpoBeta ?? 0.1, stepsPerReport: request.stepsPerReport
                        ) { iteration, loss, margin in
                            sink.emit([
                                "event": "training_progress", "adapter_name": request.name,
                                "iteration": iteration, "total_iterations": request.iterations,
                                "loss": loss, "iterations_per_second": 0.0, "tokens_per_second": margin,
                            ])
                        }
                    case "weighted", "grpo":
                        lastLoss = RLTrain.runWeighted(
                            model: context.model, samples: weightedSamples,
                            iterations: request.iterations, learningRate: request.learningRate,
                            klBeta: request.klBeta ?? 0.05, stepsPerReport: request.stepsPerReport
                        ) { iteration, loss, kl in
                            sink.emit([
                                "event": "training_progress", "adapter_name": request.name,
                                "iteration": iteration, "total_iterations": request.iterations,
                                "loss": loss, "iterations_per_second": 0.0, "tokens_per_second": kl,
                            ])
                        }
                    default:
                        try LoRATrain.train(
                            model: context.model, train: train, validate: valid,
                            optimizer: Adam(learningRate: request.learningRate),
                            tokenizer: trainingTokenizer, parameters: parameters
                        ) { progress in
                            switch progress {
                            case .train(let iteration, let loss, let iterationsPerSecond, let tokensPerSecond):
                                lastLoss = Double(loss)
                                sink.emit([
                                    "event": "training_progress", "adapter_name": request.name,
                                    "iteration": iteration, "total_iterations": request.iterations,
                                    "loss": Double(loss), "iterations_per_second": iterationsPerSecond,
                                    "tokens_per_second": tokensPerSecond,
                                ])
                            case .validation(let iteration, let validationLoss, _):
                                lastValidation = Double(validationLoss)
                                sink.emit([
                                    "event": "training_validation", "adapter_name": request.name,
                                    "iteration": iteration, "validation_loss": Double(validationLoss),
                                ])
                            case .save:
                                break
                            }
                            return .more
                        }

                        if !valid.isEmpty {
                            let finalValidation = try LoRATrain.evaluate(
                                model: context.model, dataset: valid, tokenizer: trainingTokenizer,
                                batchSize: request.batchSize, batchCount: 0
                            )
                            lastValidation = Double(finalValidation)
                            sink.emit([
                                "event": "training_validation", "adapter_name": request.name,
                                "iteration": request.iterations, "validation_loss": Double(finalValidation),
                            ])
                        }
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

// Bridge-driven GRPO: the bridge samples K completions per prompt, asks Crystal
// for each reward via the reward callback (serviced on the Crystal thread by
// drainRL), computes group-relative advantages, and runs the KL-anchored
// weighted update — for `rounds` rounds — then saves the adapter.
@_cdecl("llamero_mlx_session_grpo_loop")
public func llamero_mlx_session_grpo_loop(
    _ handle: Int64,
    _ requestJson: UnsafePointer<CChar>?,
    _ rewardCallback: LlameroRewardCallback?,
    _ rewardUserData: UnsafeMutableRawPointer?,
    _ eventCallback: LlameroEventCallback?,
    _ eventUserData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let session = BridgeRegistry.shared.session(handle) else { return 2 }
    guard let requestJson,
        let data = String(cString: requestJson).data(using: .utf8),
        let request = try? JSONDecoder().decode(GRPORequest.self, from: data)
    else { return 3 }

    let sink = EventSink(
        sessionId: "mlx-session-\(handle)", modelId: session.modelId,
        adapterStackId: session.adapterStackId
    )

    Task.detached {
        guard let container = session.container, session.loaded else {
            sink.fail(message: "Cannot run GRPO before the model is loaded", code: "grpo_failed", recoverable: true, baseModelLoaded: false)
            return
        }
        guard session.activeAdapters.isEmpty else {
            sink.fail(message: "Deactivate adapters before GRPO", code: "grpo_failed", recoverable: true, baseModelLoaded: true)
            return
        }
        let configuration = LoRAConfiguration(
            numLayers: request.numLayers, fineTuneType: .lora,
            loraParameters: .init(rank: request.rank, scale: request.scale)
        )
        let start = Date()
        do {
            try await container.perform { context in
                let tok = SpecialTokenAwareTrainingTokenizer(context.tokenizer)
                let adapter = try LoRAContainer.from(model: context.model, configuration: configuration)
                do {
                    for round in 0 ..< request.rounds {
                        var samples: [RLTrain.WeightedSample] = []
                        var rewardSum = 0.0
                        var rewardCount = 0
                        for prompt in request.prompts {
                            var comps: [String] = []
                            var rewards: [Double] = []
                            for _ in 0 ..< request.samples {
                                let input = try await context.processor.prepare(
                                    input: UserInput(chat: [Chat.Message.user(prompt)]))
                                var params = GenerateParameters()
                                params.temperature = request.temperature
                                params.maxTokens = request.maxTokens
                                var text = ""
                                let stream = try MLXLMCommon.generate(input: input, parameters: params, context: context)
                                for await gen in stream {
                                    if case .chunk(let t) = gen { text += t }
                                }
                                let reward = sink.askReward(prompt: prompt, completion: text)
                                comps.append(text); rewards.append(reward)
                                rewardSum += reward; rewardCount += 1
                            }
                            let mean = rewards.reduce(0, +) / Double(max(rewards.count, 1))
                            let variance = rewards.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(rewards.count, 1))
                            let std = variance.squareRoot()
                            if std < 1e-6 { continue } // whole group scored equally -> no advantage
                            for (i, text) in comps.enumerated() {
                                let adv = (rewards[i] - mean) / (std + 1e-4)
                                let pl = tok.encode(text: prompt).count
                                let full = tok.encode(text: prompt + text)
                                if full.count > pl {
                                    samples.append(RLTrain.WeightedSample(full: full, promptLen: pl, weight: Float(adv)))
                                }
                            }
                        }
                        let meanReward = rewardCount > 0 ? rewardSum / Double(rewardCount) : 0
                        if !samples.isEmpty {
                            // Cache references on the FROZEN base (LoRA off), then restore policy.
                            context.model.setLoRAEnabled(false)
                            RLTrain.cacheWeightedReferences(model: context.model, samples: &samples)
                            context.model.setLoRAEnabled(true)
                            _ = RLTrain.runWeighted(
                                model: context.model, samples: samples,
                                iterations: request.iterations, learningRate: request.learningRate,
                                klBeta: request.klBeta, stepsPerReport: max(request.iterations, 1)
                            ) { _, _, _ in }
                        }
                        sink.emit([
                            "event": "grpo_round", "adapter_name": request.name,
                            "round": round, "mean_reward": meanReward, "samples": samples.count,
                        ])
                    }

                    let outputURL = URL(fileURLWithPath: request.outputDir)
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    let weights = Dictionary(uniqueKeysWithValues: context.model.trainableParameters().flattened())
                    try MLX.save(arrays: weights, url: outputURL.appending(component: "adapters.safetensors"))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    try encoder.encode(configuration).write(to: outputURL.appending(component: "adapter_config.json"))
                    adapter.unload(from: context.model)
                } catch {
                    adapter.unload(from: context.model)
                    throw error
                }
            }
            sink.emit([
                "event": "training_completed", "adapter_name": request.name,
                "adapter_path": request.outputDir, "iterations": request.iterations * request.rounds,
                "final_loss": 0.0, "total_time_ms": Date().timeIntervalSince(start) * 1000,
            ])
            sink.finish()
        } catch {
            sink.fail(message: "GRPO failed: \(error)", code: "grpo_failed", recoverable: true, baseModelLoaded: session.loaded)
        }
    }

    return sink.drainRL(
        eventCallback: eventCallback, eventUserData: eventUserData,
        rewardCallback: rewardCallback, rewardUserData: rewardUserData)
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
