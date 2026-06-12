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
    /// Optional base directory for FluidAudio model artifacts.
    var modelsDir: String?

    enum CodingKeys: String, CodingKey {
        case asrModelVersion = "asr_model_version"
        case ttsVoice = "tts_voice"
        case modelsDir = "models_dir"
    }
}

struct TranscribeRequest: Codable {
    var path: String
}

struct DiarizedTranscribeConfig: Codable {
    var clusteringThreshold: Double?
    var minSpeakers: Int?
    var maxSpeakers: Int?
    var speakerCount: Int?

    enum CodingKeys: String, CodingKey {
        case clusteringThreshold = "clustering_threshold"
        case minSpeakers = "min_speakers"
        case maxSpeakers = "max_speakers"
        case speakerCount = "speaker_count"
    }
}

struct StreamConfig: Codable {
    /// Streaming chunk size in ms: 160 (default, lowest latency), 320, or
    /// 1280 (highest throughput). Each maps to a separately exported CoreML
    /// encoder of the Parakeet EOU 120M streaming model.
    var chunkMs: Int?
    /// Minimum sustained silence (ms) before end-of-utterance is confirmed.
    /// Defaults to FluidAudio's 1280ms.
    var eouDebounceMs: Int?

    enum CodingKeys: String, CodingKey {
        case chunkMs = "chunk_ms"
        case eouDebounceMs = "eou_debounce_ms"
    }
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
    var offlineDiarizerModels: OfflineDiarizerModels?
    var tts: KokoroAneManager?

    // Streaming EOU managers are expensive to load, so freed streams park
    // their manager here (already reset) and the next stream with the same
    // configuration reuses it instead of reloading the CoreML models.
    private let eouCacheLock = NSLock()
    private var eouManagerCache: [String: StreamingEouAsrManager] = [:]

    init(config: AudioRuntimeConfig) {
        self.config = config
        FluidAudio.modelsDirectoryOverride = modelsDirectory
    }

    var asrVersion: AsrModelVersion {
        config.asrModelVersion == "v2" ? .v2 : .v3
    }

    var modelsDirectory: URL? {
        guard let path = config.modelsDir?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func asrModelsDirectory(for version: AsrModelVersion) -> URL? {
        guard let root = modelsDirectory else {
            return nil
        }
        let repo: Repo = version == .v2 ? .parakeetV2 : .parakeetV3
        return root.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    func streamingModelsDirectory() -> URL? {
        modelsDirectory?.appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
    }

    func checkoutEouManager(key: String) -> StreamingEouAsrManager? {
        eouCacheLock.lock()
        defer { eouCacheLock.unlock() }
        return eouManagerCache.removeValue(forKey: key)
    }

    func storeEouManager(_ manager: StreamingEouAsrManager, key: String) {
        eouCacheLock.lock()
        defer { eouCacheLock.unlock() }
        if eouManagerCache[key] == nil {
            eouManagerCache[key] = manager
        }
    }
}

// MARK: - Streaming STT state

/// One live speech-to-text stream (llamero_audio_stream_*). The app pushes
/// 16kHz mono Float32 PCM; the bridge streams back transcript_partial frames
/// (in-progress utterance text) and utterance_end frames (one per detected
/// end of utterance), then transcript_final on finish.
///
/// FluidAudio's StreamingEouAsrManager latches its EOU flag and fires its
/// EOU callback at most once per decoding session, so the bridge resets the
/// manager after every confirmed utterance: partial transcripts therefore
/// cover the current utterance only, and the box accumulates the full
/// session text itself.
final class AudioStreamBox: @unchecked Sendable {
    let runtimeHandle: Int64
    let chunkSize: StreamingChunkSize
    let eouDebounceMs: Int

    // Touched only from the stream's serialized push/finish FFI calls
    // (each blocks its calling thread until the worker task finishes).
    var manager: StreamingEouAsrManager?
    var finished = false
    var completedUtterances: [String] = []
    var utteranceSegments: [[String: Any]] = []
    var processedSamples: Int = 0
    var lastBoundaryMs: Double = 0
    var processingTimeMs: Double = 0

    // Shared with the manager's actor-side callbacks.
    private let lock = NSLock()
    private var _sink: EventSink?
    private var _pendingUtterance: String?

    init(runtimeHandle: Int64, chunkSize: StreamingChunkSize, eouDebounceMs: Int) {
        self.runtimeHandle = runtimeHandle
        self.chunkSize = chunkSize
        self.eouDebounceMs = eouDebounceMs
    }

    var managerCacheKey: String { "\(chunkSize.modelSubdirectory)-\(eouDebounceMs)" }

    var processedMs: Double { Double(processedSamples) * 1000.0 / 16000.0 }

    var fullSessionText: String { completedUtterances.joined(separator: " ") }

    func setSink(_ sink: EventSink?) {
        lock.lock()
        defer { lock.unlock() }
        _sink = sink
    }

    var currentSink: EventSink? {
        lock.lock()
        defer { lock.unlock() }
        return _sink
    }

    func setPendingUtterance(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        _pendingUtterance = text
    }

    func takePendingUtterance() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let pending = _pendingUtterance
        _pendingUtterance = nil
        return pending
    }
}

final class AudioBridgeRegistry: @unchecked Sendable {
    static let shared = AudioBridgeRegistry()
    private let lock = NSLock()
    private var nextHandle: Int64 = 1
    private var runtimes: [Int64: AudioRuntimeBox] = [:]
    private var streams: [Int64: AudioStreamBox] = [:]

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
        // Streams cannot outlive their parent runtime.
        streams = streams.filter { $0.value.runtimeHandle != handle }
    }

    func addStream(_ stream: AudioStreamBox) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        streams[handle] = stream
        return handle
    }

    func stream(_ handle: Int64) -> AudioStreamBox? {
        lock.lock(); defer { lock.unlock() }
        return streams[handle]
    }

    func removeStream(_ handle: Int64) -> AudioStreamBox? {
        lock.lock(); defer { lock.unlock() }
        return streams.removeValue(forKey: handle)
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
        to: runtime.asrModelsDirectory(for: version),
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

/// Loads the offline diarization CoreML bundles on first use. The models are
/// parked on the runtime and reused by future diarized transcriptions; each
/// call creates a fresh OfflineDiarizerManager around the resident models so
/// per-call clustering/speaker-count config can vary without reloading.
private func ensureOfflineDiarizerModels(_ runtime: AudioRuntimeBox, sink: EventSink) async throws
    -> OfflineDiarizerModels
{
    if let models = runtime.offlineDiarizerModels {
        return models
    }

    sink.emit([
        "event": "diarizer_model_load_started",
        "model_version": "offline-vbx",
    ])
    let start = Date()

    let throttle = ProgressThrottle()
    let models = try await OfflineDiarizerModels.load(
        from: runtime.modelsDirectory,
        progressHandler: { progress in
            let fraction = progress.fractionCompleted
            if throttle.shouldReport(fraction) {
                sink.emit([
                    "event": "diarizer_model_load_progress",
                    "progress": fraction,
                ])
            }
        }
    )

    runtime.offlineDiarizerModels = models
    sink.emit([
        "event": "diarizer_model_loaded",
        "model_version": "offline-vbx",
        "load_time_ms": Date().timeIntervalSince(start) * 1000,
    ])
    return models
}

/// Loads the Kokoro TTS chain on first use, emitting progress events.
private func ensureTts(_ runtime: AudioRuntimeBox, sink: EventSink) async throws -> KokoroAneManager {
    if let tts = runtime.tts {
        return tts
    }

    sink.emit(["event": "tts_model_load_started"])
    let start = Date()

    let tts = KokoroAneManager(defaultVoice: runtime.config.ttsVoice, directory: runtime.modelsDirectory)
    try await tts.initialize()

    runtime.tts = tts
    sink.emit([
        "event": "tts_model_loaded",
        "load_time_ms": Date().timeIntervalSince(start) * 1000,
    ])
    return tts
}

// MARK: - Transcript segments

private struct WordSpan {
    let text: String
    let startMs: Double
    let endMs: Double

    var midpointMs: Double { (startMs + endMs) / 2 }
}

/// Groups Parakeet's subword token timings into word-level segments
/// ({text, start_ms, end_ms}). Tokens use the SentencePiece word-boundary
/// marker; a token starting a new word flushes the previous one.
private func wordSpans(from timings: [TokenTiming]) -> [WordSpan] {
    var segments: [WordSpan] = []
    var currentText = ""
    var start: TimeInterval = 0
    var end: TimeInterval = 0

    func flush() {
        let trimmed = currentText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        segments.append(WordSpan(text: trimmed, startMs: start * 1000, endMs: end * 1000))
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

private func wordSegments(from timings: [TokenTiming]) -> [[String: Any]] {
    wordSpans(from: timings).map { word in
        [
            "text": word.text,
            "start_ms": word.startMs,
            "end_ms": word.endMs,
        ]
    }
}

private func wordSegments(from spans: [WordSpan]) -> [[String: Any]] {
    spans.map { word in
        [
            "text": word.text,
            "start_ms": word.startMs,
            "end_ms": word.endMs,
        ]
    }
}

private func audioDurationMs(for url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else {
        return 0.0
    }
    let sampleRate = file.processingFormat.sampleRate
    guard sampleRate > 0 else {
        return 0.0
    }
    return Double(file.length) * 1000.0 / sampleRate
}

private func diarizerConfig(from config: DiarizedTranscribeConfig) -> OfflineDiarizerConfig {
    var diarizerConfig = OfflineDiarizerConfig.default
    if let threshold = config.clusteringThreshold {
        diarizerConfig.clustering.threshold = threshold
    }
    if let count = config.speakerCount {
        diarizerConfig.clustering.numSpeakers = count
    }
    if let minSpeakers = config.minSpeakers {
        diarizerConfig.clustering.minSpeakers = minSpeakers
    }
    if let maxSpeakers = config.maxSpeakers {
        diarizerConfig.clustering.maxSpeakers = maxSpeakers
    }
    return diarizerConfig
}

private func attributedSegments(
    words: [WordSpan],
    diarizationSegments: [TimedSpeakerSegment],
    fallbackText: String,
    durationMs: Double
) -> [[String: Any]] {
    let sortedDiarization = diarizationSegments.sorted {
        if $0.startTimeSeconds == $1.startTimeSeconds {
            return $0.endTimeSeconds < $1.endTimeSeconds
        }
        return $0.startTimeSeconds < $1.startTimeSeconds
    }

    guard !sortedDiarization.isEmpty else {
        return fallbackText.isEmpty
            ? []
            : [[
                "speaker": "S1",
                "start_ms": words.first?.startMs ?? 0.0,
                "end_ms": max(durationMs, words.last?.endMs ?? 0.0),
                "text": fallbackText,
            ]]
    }

    guard !words.isEmpty else {
        return fallbackText.isEmpty
            ? []
            : [[
                "speaker": "S1",
                "start_ms": 0.0,
                "end_ms": durationMs,
                "text": fallbackText,
            ]]
    }

    var wordsByDiarizationIndex: [Int: [WordSpan]] = [:]
    for word in words {
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, diarized) in sortedDiarization.enumerated() {
            let startMs = Double(diarized.startTimeSeconds) * 1000
            let endMs = Double(diarized.endTimeSeconds) * 1000
            let distance: Double
            if word.midpointMs >= startMs && word.midpointMs <= endMs {
                distance = 0
            } else if word.midpointMs < startMs {
                distance = startMs - word.midpointMs
            } else {
                distance = word.midpointMs - endMs
            }
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        wordsByDiarizationIndex[bestIndex, default: []].append(word)
    }

    var segments: [[String: Any]] = []
    for (index, diarized) in sortedDiarization.enumerated() {
        let startMs = Double(diarized.startTimeSeconds) * 1000
        let endMs = Double(diarized.endTimeSeconds) * 1000
        let matchingWords = wordsByDiarizationIndex[index] ?? []
        guard !matchingWords.isEmpty else { continue }

        let text = matchingWords.map(\.text).joined(separator: " ")
        segments.append([
            "speaker": diarized.speakerId,
            "start_ms": min(startMs, matchingWords.first?.startMs ?? startMs),
            "end_ms": max(endMs, matchingWords.last?.endMs ?? endMs),
            "text": text,
        ])
    }

    if segments.isEmpty && !fallbackText.isEmpty {
        segments.append([
            "speaker": "S1",
            "start_ms": 0.0,
            "end_ms": durationMs,
            "text": fallbackText,
        ])
    }

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
            let fileDurationMs = audioDurationMs(for: URL(fileURLWithPath: request.path))
            let durationMs = max(
                fileDurationMs,
                result.duration * 1000,
                segments.compactMap { $0["end_ms"] as? Double }.max() ?? 0.0
            )
            if segments.isEmpty && !result.text.isEmpty {
                // No token timings: a single segment spanning the audio.
                segments = [[
                    "text": result.text,
                    "start_ms": 0.0,
                    "end_ms": durationMs,
                ]]
            }

            sink.emit([
                "event": "transcript_final",
                "text": result.text,
                "segments": segments,
                "duration_ms": durationMs,
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

@_cdecl("llamero_audio_runtime_transcribe_diarized")
public func llamero_audio_runtime_transcribe_diarized(
    _ handle: Int64,
    _ pathCString: UnsafePointer<CChar>?,
    _ configJson: UnsafePointer<CChar>?,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let runtime = AudioBridgeRegistry.shared.runtime(handle) else { return 2 }
    guard let pathCString else { return 3 }

    let path = String(cString: pathCString)
    let config: DiarizedTranscribeConfig
    if let configJson {
        guard let data = String(cString: configJson).data(using: .utf8),
            let decoded = try? JSONDecoder().decode(DiarizedTranscribeConfig.self, from: data)
        else { return 3 }
        config = decoded
    } else {
        config = DiarizedTranscribeConfig()
    }

    let sink = EventSink(sessionId: "audio-runtime-\(handle)")

    Task.detached {
        do {
            guard FileManager.default.fileExists(atPath: path) else {
                throw AudioBridgeError(message: "Audio file not found: \(path)")
            }

            let totalStart = Date()

            let asrManager = try await ensureAsrManager(runtime, sink: sink)
            var decoderState = TdtDecoderState.make(decoderLayers: runtime.asrDecoderLayers)
            let asrResult = try await asrManager.transcribe(
                URL(fileURLWithPath: path), decoderState: &decoderState)

            let wordsFromTimings = wordSpans(from: asrResult.tokenTimings ?? [])
            let words: [WordSpan]
            if wordsFromTimings.isEmpty && !asrResult.text.isEmpty {
                words = [
                    WordSpan(
                        text: asrResult.text,
                        startMs: 0,
                        endMs: asrResult.duration * 1000
                    )
                ]
            } else {
                words = wordsFromTimings
            }

            let diarizerModels = try await ensureOfflineDiarizerModels(runtime, sink: sink)
            let diarizationConfig = diarizerConfig(from: config)
            let diarizer = OfflineDiarizerManager(config: diarizationConfig)
            diarizer.initialize(models: diarizerModels)

            let diarizationStart = Date()
            let diarization = try await diarizer.process(URL(fileURLWithPath: path)) {
                chunksProcessed, totalChunks in
                let progress = totalChunks > 0 ? Double(chunksProcessed) / Double(totalChunks) : 1.0
                sink.emit([
                    "event": "diarization_progress",
                    "progress": progress,
                    "chunks_processed": chunksProcessed,
                    "total_chunks": totalChunks,
                ])
            }
            let diarizationProcessingMs = Date().timeIntervalSince(diarizationStart) * 1000
            let speakerDurationMs =
                diarization.segments.map { Double($0.endTimeSeconds) * 1000 }.max() ?? 0
            let fileDurationMs = audioDurationMs(for: URL(fileURLWithPath: path))
            let durationMs = max(
                asrResult.duration * 1000,
                words.last?.endMs ?? 0,
                speakerDurationMs,
                fileDurationMs
            )

            let speakerSegments = attributedSegments(
                words: words,
                diarizationSegments: diarization.segments,
                fallbackText: asrResult.text,
                durationMs: durationMs
            )

            let rawSpeakerSegments = diarization.segments
                .sorted {
                    if $0.startTimeSeconds == $1.startTimeSeconds {
                        return $0.endTimeSeconds < $1.endTimeSeconds
                    }
                    return $0.startTimeSeconds < $1.startTimeSeconds
                }
                .map { segment in
                    [
                        "speaker": segment.speakerId,
                        "start_ms": Double(segment.startTimeSeconds) * 1000,
                        "end_ms": Double(segment.endTimeSeconds) * 1000,
                    ] as [String: Any]
                }

            sink.emit([
                "event": "diarized_transcript_final",
                "text": asrResult.text,
                "segments": speakerSegments,
                "word_segments": wordSegments(from: words),
                "speaker_segments": rawSpeakerSegments,
                "duration_ms": durationMs,
                "processing_time_ms": Date().timeIntervalSince(totalStart) * 1000,
                "asr_processing_time_ms": asrResult.processingTime * 1000,
                "diarization_processing_time_ms": diarizationProcessingMs,
                "confidence": Double(asrResult.confidence),
            ])
            sink.finish()
        } catch {
            sink.fail(
                message: "Diarized transcription failed: \(error)",
                code: "diarization_failed",
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

// MARK: - Streaming STT helpers

/// The PCM format the streaming ABI accepts: 16kHz mono Float32.
private let streamPcmFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

private func makeStreamPcmBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer? {
    let count = samples.count
    guard
        let buffer = AVAudioPCMBuffer(
            pcmFormat: streamPcmFormat, frameCapacity: AVAudioFrameCount(max(count, 1)))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(count)
    if count > 0, let channel = buffer.floatChannelData?[0] {
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: count)
        }
    }
    return buffer
}

/// Loads (or checks out from the parent runtime's cache) the Parakeet EOU
/// streaming manager on a stream's first push, emitting asr_model_load_*
/// events when a real load happens. Callbacks are (re)bound to this stream's
/// box every time because a cached manager still carries the previous
/// stream's closures.
private func ensureStreamManager(_ box: AudioStreamBox, sink: EventSink) async throws
    -> StreamingEouAsrManager
{
    if let manager = box.manager {
        return manager
    }
    guard let runtime = AudioBridgeRegistry.shared.runtime(box.runtimeHandle) else {
        throw AudioBridgeError(message: "Parent audio runtime was freed")
    }

    let manager: StreamingEouAsrManager
    if let cached = runtime.checkoutEouManager(key: box.managerCacheKey) {
        manager = cached
    } else {
        let label = "eou-\(box.chunkSize.modelSubdirectory)"
        sink.emit([
            "event": "asr_model_load_started",
            "model_version": label,
        ])
        let start = Date()
        let throttle = ProgressThrottle()
        let fresh = StreamingEouAsrManager(
            chunkSize: box.chunkSize, eouDebounceMs: box.eouDebounceMs)
        try await fresh.loadModels(
            to: runtime.streamingModelsDirectory(), configuration: nil,
            progressHandler: { progress in
                if throttle.shouldReport(progress.fractionCompleted) {
                    sink.emit([
                        "event": "asr_model_load_progress",
                        "progress": progress.fractionCompleted,
                    ])
                }
            }
        )
        sink.emit([
            "event": "asr_model_loaded",
            "model_version": label,
            "load_time_ms": Date().timeIntervalSince(start) * 1000,
        ])
        manager = fresh
    }

    // Partial hypotheses go straight to whichever sink the current FFI call
    // installed; utterance ends are queued and emitted (with timestamps)
    // back on the push worker after the chunk that confirmed them.
    await manager.setPartialTranscriptCallback { [weak box] text in
        guard let box else { return }
        box.currentSink?.emit(["event": "transcript_partial", "text": text])
    }
    await manager.setEouCallback { [weak box] transcript in
        box?.setPendingUtterance(transcript)
    }
    await manager.reset()

    box.manager = manager
    return manager
}

/// Emits one utterance_end frame and records it in the session accumulators.
/// Timestamps are derived from pushed-sample counts (16kHz), so they are
/// accurate to push granularity rather than token-exact.
private func emitStreamUtterance(_ box: AudioStreamBox, sink: EventSink, text: String) {
    let endMs = box.processedMs
    defer { box.lastBoundaryMs = endMs }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    sink.emit([
        "event": "utterance_end",
        "text": trimmed,
        "start_ms": box.lastBoundaryMs,
        "end_ms": endMs,
    ])
    box.completedUtterances.append(trimmed)
    box.utteranceSegments.append([
        "text": trimmed,
        "start_ms": box.lastBoundaryMs,
        "end_ms": endMs,
    ])
}

// MARK: - Streaming STT entry points

/// Creates a speech-to-text stream on a runtime. Config JSON (all optional):
/// {"chunk_ms": 160|320|1280, "eou_debounce_ms": 1280}. Returns a positive
/// handle, or a negative status (-1 unknown runtime, -2 bad config JSON,
/// -3 unsupported chunk_ms). Nothing is loaded here: the Parakeet EOU
/// streaming models load lazily on the first push.
@_cdecl("llamero_audio_stream_create")
public func llamero_audio_stream_create(
    _ runtimeHandle: Int64,
    _ configJson: UnsafePointer<CChar>?
) -> Int64 {
    guard AudioBridgeRegistry.shared.runtime(runtimeHandle) != nil else { return -1 }

    let config: StreamConfig
    if let configJson {
        guard let data = String(cString: configJson).data(using: .utf8),
            let decoded = try? JSONDecoder().decode(StreamConfig.self, from: data)
        else { return -2 }
        config = decoded
    } else {
        config = StreamConfig()
    }

    let chunkSize: StreamingChunkSize
    switch config.chunkMs ?? 160 {
    case 160: chunkSize = .ms160
    case 320: chunkSize = .ms320
    case 1280: chunkSize = .ms1280
    default: return -3
    }

    let box = AudioStreamBox(
        runtimeHandle: runtimeHandle,
        chunkSize: chunkSize,
        eouDebounceMs: config.eouDebounceMs ?? 1280
    )
    return AudioBridgeRegistry.shared.addStream(box)
}

/// Pushes PCM samples into a stream. `samples` MUST be 16kHz mono Float32
/// (the Crystal side passes a Slice(Float32)); no resampling happens here.
/// Emits transcript_partial frames as tokens decode and utterance_end frames
/// as end-of-utterance is confirmed (after the configured debounce silence).
/// Status: 0 ok, 2 unknown stream, 3 bad arguments, 4 stream already
/// finished.
@_cdecl("llamero_audio_stream_push")
public func llamero_audio_stream_push(
    _ handle: Int64,
    _ samples: UnsafePointer<Float>?,
    _ count: Int32,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let box = AudioBridgeRegistry.shared.stream(handle) else { return 2 }
    guard !box.finished else { return 4 }
    guard let samples, count >= 0 else { return 3 }
    guard count > 0 else { return 0 }

    // Copy out of the caller's buffer before handing off to the worker task.
    let pushed = Array(UnsafeBufferPointer(start: samples, count: Int(count)))

    let sink = EventSink(sessionId: "audio-stream-\(handle)")
    box.setSink(sink)

    Task.detached {
        do {
            let manager = try await ensureStreamManager(box, sink: sink)
            let start = Date()

            // Feed in shift-sized steps so each processBufferedAudio call
            // advances at most one encoder chunk: a confirmed EOU is then
            // handled (utterance emitted + manager reset) before the next
            // chunk decodes, so no next-utterance tokens are lost to the
            // reset.
            let step = box.chunkSize.shiftSamples
            var index = 0
            while index < pushed.count {
                let end = min(index + step, pushed.count)
                guard let buffer = makeStreamPcmBuffer(pushed[index..<end]) else {
                    throw AudioBridgeError(message: "Failed to allocate PCM buffer")
                }
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
                box.processedSamples += end - index

                if let utterance = box.takePendingUtterance() {
                    emitStreamUtterance(box, sink: sink, text: utterance)
                    // The EOU flag and callback latch once per decoding
                    // session; reset re-arms them for the next utterance
                    // (models stay loaded).
                    await manager.reset()
                }
                index = end
            }

            box.processingTimeMs += Date().timeIntervalSince(start) * 1000
            sink.finish()
        } catch {
            sink.fail(
                message: "Streaming transcription failed: \(error)",
                code: "stream_failed",
                recoverable: true
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}

/// Flushes a stream: processes any remaining buffered audio (padded to a
/// full chunk), emits a final utterance_end if speech was still pending,
/// then a transcript_final frame carrying the full session text and
/// per-utterance segments. The stream is unusable afterwards (free it with
/// llamero_audio_stream_free). Status: 0 ok, 2 unknown stream, 4 already
/// finished.
@_cdecl("llamero_audio_stream_finish")
public func llamero_audio_stream_finish(
    _ handle: Int64,
    _ callback: LlameroEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let box = AudioBridgeRegistry.shared.stream(handle) else { return 2 }
    guard !box.finished else { return 4 }
    // Mark finished on the calling thread so the stream is unusable even if
    // the flush below fails.
    box.finished = true

    let sink = EventSink(sessionId: "audio-stream-\(handle)")
    box.setSink(sink)

    Task.detached {
        do {
            if let manager = box.manager {
                let start = Date()
                // finish() pads + processes the remaining buffer and returns
                // everything accumulated since the last reset - i.e. the
                // trailing utterance that never hit an EOU boundary.
                let trailing = try await manager.finish()
                box.processingTimeMs += Date().timeIntervalSince(start) * 1000
                // Any EOU confirmed during the flush is part of `trailing`.
                _ = box.takePendingUtterance()
                emitStreamUtterance(box, sink: sink, text: trailing)
            }

            sink.emit([
                "event": "transcript_final",
                "text": box.fullSessionText,
                "segments": box.utteranceSegments,
                "duration_ms": box.processedMs,
                "processing_time_ms": box.processingTimeMs,
            ])
            sink.finish()
        } catch {
            sink.fail(
                message: "Streaming transcription failed to finish: \(error)",
                code: "stream_failed",
                recoverable: true
            )
        }
    }

    return sink.drain(callback: callback, userData: userData)
}

/// Frees a stream handle. The (already reset) EOU manager is parked on the
/// parent runtime so the next stream with the same configuration skips the
/// model load.
@_cdecl("llamero_audio_stream_free")
public func llamero_audio_stream_free(_ handle: Int64) {
    guard let box = AudioBridgeRegistry.shared.removeStream(handle) else { return }
    box.setSink(nil)
    guard let manager = box.manager else { return }
    box.manager = nil

    let runtimeHandle = box.runtimeHandle
    let cacheKey = box.managerCacheKey
    Task.detached {
        // Reset BEFORE parking so a checkout never observes mid-reset state.
        await manager.reset()
        AudioBridgeRegistry.shared.runtime(runtimeHandle)?
            .storeEouManager(manager, key: cacheKey)
    }
}
