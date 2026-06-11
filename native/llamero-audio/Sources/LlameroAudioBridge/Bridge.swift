// C ABI bridge between Crystal (src/native/audio_bridge.cr) and FluidAudio's
// CoreML/ANE speech runtime (Parakeet ASR + Kokoro TTS). The contract:
//
// - Handles are opaque positive Int64 tokens kept in AudioBridgeRegistry.
// - Requests/configs cross as JSON strings (snake_case keys).
// - Results stream back as JSON event frames through a C callback that is
//   ALWAYS invoked on the calling thread (Crystal's GC cannot tolerate
//   callbacks from foreign threads). Async FluidAudio work runs in a
//   detached Task that feeds an EventSink; the calling thread drains the
//   sink until the task finishes.
// - The bridge must NEVER depend on the main dispatch queue being serviced:
//   the Crystal host's main thread is blocked inside the FFI call.
// - Errors surface both as an `error` event frame and a nonzero status.
//
// Models are loaded lazily on first use (first transcribe / first speak),
// emitting *_model_load_started / *_model_loaded events, so creating a
// runtime is cheap and apps only pay for the models they touch.

import AVFoundation
import FluidAudio
import Foundation

public typealias LlameroEventCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

// MARK: - JSON payloads from Crystal

struct AudioRuntimeConfig: Codable {
    /// Parakeet model generation: "v3" (default, 25 EU languages + ja) or
    /// "v2" (English-only).
    var asrModelVersion: String?
    /// Default Kokoro voice (e.g. "af_heart"); per-request voice overrides it.
    var ttsVoice: String?

    enum CodingKeys: String, CodingKey {
        case asrModelVersion = "asr_model_version"
        case ttsVoice = "tts_voice"
    }
}

struct TranscribeRequest: Codable {
    var path: String
}

struct SpeakRequest: Codable {
    var text: String
    var voice: String?
    var outputPath: String?

    enum CodingKeys: String, CodingKey {
        case text, voice
        case outputPath = "output_path"
    }
}

struct AudioBridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Handle registry

final class AudioRuntimeBox: @unchecked Sendable {
    let config: AudioRuntimeConfig

    // Lazily populated on first transcribe/speak. FFI calls from Crystal are
    // serialized (each blocks its calling thread until the event stream
    // finishes), so plain ivars are safe here - same pattern as the MLX
    // bridge's SessionBox.
    var asrManager: AsrManager?
    var asrDecoderLayers: Int = 2
    var tts: KokoroAneManager?

    init(config: AudioRuntimeConfig) { self.config = config }

    var asrVersion: AsrModelVersion {
        config.asrModelVersion == "v2" ? .v2 : .v3
    }
}

final class AudioBridgeRegistry: @unchecked Sendable {
    static let shared = AudioBridgeRegistry()
    private let lock = NSLock()
    private var nextHandle: Int64 = 1
    private var runtimes: [Int64: AudioRuntimeBox] = [:]

    func addRuntime(_ runtime: AudioRuntimeBox) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        runtimes[handle] = runtime
        return handle
    }

    func runtime(_ handle: Int64) -> AudioRuntimeBox? {
        lock.lock(); defer { lock.unlock() }
        return runtimes[handle]
    }

    func removeRuntime(_ handle: Int64) {
        lock.lock(); defer { lock.unlock() }
        runtimes[handle] = nil
    }
}

// MARK: - Event sink (async producer, calling-thread consumer)

final class EventSink: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [String] = []
    private var finished = false
    private var status: Int32 = 0

    private let sessionId: String

    private static let timestampFormatter = ISO8601DateFormatter()

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func emit(_ payload: [String: Any]) {
        var frame = payload
        frame["session_id"] = sessionId
        frame["created_at"] = Self.timestampFormatter.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
            let json = String(data: data, encoding: .utf8)
        else { return }

        condition.lock()
        pending.append(json)
        condition.signal()
        condition.unlock()
    }

    func fail(message: String, code: String, recoverable: Bool) {
        emit([
            "event": "error",
            "message": message,
            "code": code,
            "recoverable": recoverable,
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

// MARK: - Lazy model loading

/// Whole-percent progress throttle, safe to call from any queue.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported = -1.0

    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fraction - lastReported >= 0.01 || fraction >= 1.0 {
            lastReported = fraction
            return true
        }
        return false
    }
}

/// Loads the Parakeet ASR models on first use, emitting progress events.
/// FluidAudio downloads its CoreML models from its own Hugging Face repos;
/// the download path uses URLSession (not a main-actor hop), but verifying
/// it under a non-Swift host is a known on-device check (see the multimodal
/// roadmap).
private func ensureAsrManager(_ runtime: AudioRuntimeBox, sink: EventSink) async throws -> AsrManager {
    if let manager = runtime.asrManager {
        return manager
    }

    let version = runtime.asrVersion
    sink.emit([
        "event": "asr_model_load_started",
        "model_version": version == .v2 ? "v2" : "v3",
    ])
    let start = Date()

    // The progress handler runs on an unspecified queue; throttle state
    // lives behind a lock so the closure stays Sendable.
    let throttle = ProgressThrottle()
    let models = try await AsrModels.downloadAndLoad(
        version: version,
        progressHandler: { progress in
            // Throttle to whole-percent steps; frames cross an FFI boundary.
            let fraction = progress.fractionCompleted
            if throttle.shouldReport(fraction) {
                sink.emit([
                    "event": "asr_model_load_progress",
                    "progress": fraction,
                ])
            }
        }
    )
    let manager = AsrManager(models: models)

    runtime.asrManager = manager
    runtime.asrDecoderLayers = models.version.decoderLayers

    sink.emit([
        "event": "asr_model_loaded",
        "model_version": version == .v2 ? "v2" : "v3",
        "load_time_ms": Date().timeIntervalSince(start) * 1000,
    ])
    return manager
}

/// Loads the Kokoro TTS chain on first use, emitting progress events.
private func ensureTts(_ runtime: AudioRuntimeBox, sink: EventSink) async throws -> KokoroAneManager {
    if let tts = runtime.tts {
        return tts
    }

    sink.emit(["event": "tts_model_load_started"])
    let start = Date()

    let tts = KokoroAneManager(defaultVoice: runtime.config.ttsVoice)
    try await tts.initialize()

    runtime.tts = tts
    sink.emit([
        "event": "tts_model_loaded",
        "load_time_ms": Date().timeIntervalSince(start) * 1000,
    ])
    return tts
}

// MARK: - Transcript segments

/// Groups Parakeet's subword token timings into word-level segments
/// ({text, start_ms, end_ms}). Tokens use the SentencePiece word-boundary
/// marker; a token starting a new word flushes the previous one.
private func wordSegments(from timings: [TokenTiming]) -> [[String: Any]] {
    var segments: [[String: Any]] = []
    var currentText = ""
    var start: TimeInterval = 0
    var end: TimeInterval = 0

    func flush() {
        let trimmed = currentText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        segments.append([
            "text": trimmed,
            "start_ms": start * 1000,
            "end_ms": end * 1000,
        ])
    }

    for timing in timings {
        let token = timing.token.replacingOccurrences(of: "\u{2581}", with: " ")
        if token.hasPrefix(" ") && !currentText.isEmpty {
            flush()
            currentText = ""
        }
        if currentText.isEmpty {
            start = timing.startTime
        }
        currentText += token
        end = timing.endTime
    }
    flush()
    return segments
}

// MARK: - C ABI entry points

@_cdecl("llamero_audio_runtime_create")
public func llamero_audio_runtime_create(_ configJson: UnsafePointer<CChar>?) -> Int64 {
    let config: AudioRuntimeConfig
    if let configJson,
        let data = String(cString: configJson).data(using: .utf8),
        let decoded = try? JSONDecoder().decode(AudioRuntimeConfig.self, from: data)
    {
        config = decoded
    } else if configJson == nil {
        config = AudioRuntimeConfig()
    } else {
        return -1
    }
    // Nothing is loaded here: ASR/TTS models load lazily on first use so
    // runtime creation stays instant and apps only pay for what they touch.
    return AudioBridgeRegistry.shared.addRuntime(AudioRuntimeBox(config: config))
}

@_cdecl("llamero_audio_runtime_free")
public func llamero_audio_runtime_free(_ handle: Int64) {
    AudioBridgeRegistry.shared.removeRuntime(handle)
}

@_cdecl("llamero_audio_transcribe_file")
public func llamero_audio_transcribe_file(
    _ handle: Int64,
    _ requestJson: UnsafePointer<CChar>?,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let runtime = AudioBridgeRegistry.shared.runtime(handle) else { return 2 }
    guard let requestJson,
        let data = String(cString: requestJson).data(using: .utf8),
        let request = try? JSONDecoder().decode(TranscribeRequest.self, from: data)
    else { return 3 }

    let sink = EventSink(sessionId: "audio-runtime-\(handle)")

    Task.detached {
        do {
            guard FileManager.default.fileExists(atPath: request.path) else {
                throw AudioBridgeError(message: "Audio file not found: \(request.path)")
            }

            let manager = try await ensureAsrManager(runtime, sink: sink)

            // Fresh decoder state per one-shot transcription. AsrManager's
            // URL overload reads the file via AVAudioFile and resamples to
            // the 16kHz mono Float32 the models expect.
            var decoderState = TdtDecoderState.make(decoderLayers: runtime.asrDecoderLayers)
            let result = try await manager.transcribe(
                URL(fileURLWithPath: request.path), decoderState: &decoderState)

            var segments = wordSegments(from: result.tokenTimings ?? [])
            if segments.isEmpty && !result.text.isEmpty {
                // No token timings: a single segment spanning the audio.
                segments = [[
                    "text": result.text,
                    "start_ms": 0.0,
                    "end_ms": result.duration * 1000,
                ]]
            }

            sink.emit([
                "event": "transcript_final",
                "text": result.text,
                "segments": segments,
                "duration_ms": result.duration * 1000,
                "processing_time_ms": result.processingTime * 1000,
                "confidence": Double(result.confidence),
            ])
            sink.finish()
        } catch {
            sink.fail(
                message: "Transcription failed: \(error)",
                code: "transcription_failed",
                recoverable: true
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}

/// Splits text into speakable chunks at sentence boundaries, keeping each
/// under maxLength characters (falling back to comma/space splits for run-on
/// sentences) so Kokoro never sees a phoneme sequence it rejects.
func sentenceChunks(_ text: String, maxLength: Int) -> [String] {
    var chunks: [String] = []
    var current = ""

    func flush() {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { chunks.append(trimmed) }
        current = ""
    }

    var sentences: [String] = []
    var sentence = ""
    for character in text {
        sentence.append(character)
        if character == "." || character == "!" || character == "?" || character == "\n" {
            sentences.append(sentence)
            sentence = ""
        }
    }
    if !sentence.isEmpty { sentences.append(sentence) }

    for piece in sentences {
        // Oversized single sentence: split on commas, then hard-wrap on spaces.
        if piece.count > maxLength {
            flush()
            var fragment = ""
            for word in piece.split(separator: " ", omittingEmptySubsequences: false) {
                if fragment.count + word.count + 1 > maxLength {
                    chunks.append(fragment.trimmingCharacters(in: .whitespacesAndNewlines))
                    fragment = ""
                }
                fragment += fragment.isEmpty ? String(word) : " " + String(word)
            }
            if !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(fragment.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            continue
        }

        if current.count + piece.count > maxLength {
            flush()
        }
        current += piece
    }
    flush()

    return chunks.isEmpty ? [text] : chunks
}

@_cdecl("llamero_audio_speak")
public func llamero_audio_speak(
    _ handle: Int64,
    _ requestJson: UnsafePointer<CChar>?,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let runtime = AudioBridgeRegistry.shared.runtime(handle) else { return 2 }
    guard let requestJson,
        let data = String(cString: requestJson).data(using: .utf8),
        let request = try? JSONDecoder().decode(SpeakRequest.self, from: data)
    else { return 3 }

    let sink = EventSink(sessionId: "audio-runtime-\(handle)")

    Task.detached {
        do {
            guard !request.text.isEmpty else {
                throw AudioBridgeError(message: "Cannot speak empty text")
            }

            let tts = try await ensureTts(runtime, sink: sink)

            // Kokoro rejects long inputs (phonemeSequenceTooLong), so
            // synthesize sentence chunks and concatenate the samples.
            let voice = request.voice ?? runtime.config.ttsVoice
            let chunks = sentenceChunks(request.text, maxLength: 300)

            let start = Date()
            var samples: [Float] = []
            var sampleRate = 24000
            var durationSeconds = 0.0
            for chunk in chunks {
                let result = try await tts.synthesizeDetailed(text: chunk, voice: voice)
                samples.append(contentsOf: result.samples)
                sampleRate = result.sampleRate
                durationSeconds += result.durationSeconds
            }
            let wav = try AudioWAV.data(
                from: samples, sampleRate: Double(sampleRate))

            let outputPath =
                request.outputPath
                ?? NSTemporaryDirectory() + "llamero-speak-\(UUID().uuidString).wav"
            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wav.write(to: outputURL)

            sink.emit([
                "event": "speak_completed",
                "path": outputPath,
                "duration_ms": durationSeconds * 1000,
                "synthesis_time_ms": Date().timeIntervalSince(start) * 1000,
                "sample_rate": sampleRate,
            ])
            sink.finish()
        } catch {
            sink.fail(
                message: "Speech synthesis failed: \(error)",
                code: "speak_failed",
                recoverable: true
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}
