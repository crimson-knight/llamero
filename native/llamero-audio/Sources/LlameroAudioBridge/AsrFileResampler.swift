// Reads an audio file as the 16 kHz mono Float32 samples Parakeet expects,
// through one AVAudioConverter per (source rate, target rate) kept for the
// life of the process.
//
// FluidAudio's `AsrManager.transcribe(URL)` resamples with a converter it
// builds per call, and every new converter rebuilds its sinc resampler
// (Mastering algorithm, max quality: about 2.7 MB of Kaiser-window tables,
// built twice as the algorithm and then the quality are set). A dictation
// app transcribes the same microphone rate over and over, so the bridge
// builds that converter once and resets it between files instead.
//
// The conversion is the one FluidAudio's `AudioConverter` performs (same
// algorithm, quality, buffer sizing and drain loop), so the samples match
// the URL path's sample for sample. Files the cached path does not cover
// (more than one channel, or longer than FluidAudio's disk-backed
// threshold) return nil, and the caller keeps FluidAudio's URL path.

import AVFoundation
import FluidAudio
import Foundation

final class AsrFileResampler: @unchecked Sendable {
    static let shared = AsrFileResampler()

    struct RatePair: Hashable {
        let sourceRate: Double
        let targetRate: Double
    }

    // One converter and the lock that keeps two transcriptions from sharing
    // it at once.
    private final class CachedConverter {
        let converter: AVAudioConverter
        let lock = NSLock()

        init(converter: AVAudioConverter) {
            self.converter = converter
        }
    }

    private let cacheLock = NSLock()
    private var convertersByRatePair: [RatePair: CachedConverter] = [:]

    /// The rate pairs that have a converter, for tests and diagnostics.
    var cachedRatePairs: Set<RatePair> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return Set(convertersByRatePair.keys)
    }

    /// The file's samples at `config.sampleRate`, mono Float32, or nil when
    /// the file has more than one channel or is long enough for FluidAudio's
    /// disk-backed path (`config.streamingEnabled` and more than
    /// `config.streamingThreshold` samples at the target rate).
    func asrSamples(of url: URL, config: ASRConfig = .default) throws -> [Float]? {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        guard format.channelCount == 1, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            return nil
        }

        let targetRate = Double(config.sampleRate)
        if config.streamingEnabled {
            let estimatedSamples = Int((Double(audioFile.length) * targetRate / format.sampleRate).rounded(.up))
            if estimatedSamples > config.streamingThreshold { return nil }
        }

        let samples = try readSamples(of: audioFile)
        return try resample(samples, from: format.sampleRate, to: targetRate)
    }

    /// `samples` (mono Float32 at `sourceRate`) at `targetRate`.
    func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        if sourceRate == targetRate { return samples }

        let cached = try cachedConverter(for: RatePair(sourceRate: sourceRate, targetRate: targetRate))
        cached.lock.lock(); defer { cached.lock.unlock() }
        let converter = cached.converter
        // A converter that reached end of stream must be reset before it
        // takes new input; reset also clears the resampler's history, so
        // each file converts exactly as with a fresh converter.
        converter.reset()

        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw AudioBridgeError(message: "Failed to allocate a \(samples.count)-frame resampler input buffer")
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = inputBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { source in
                channelData[0].update(from: source.baseAddress!, count: samples.count)
            }
        }

        return try convert(inputBuffer, with: converter)
    }

    private func cachedConverter(for ratePair: RatePair) throws -> CachedConverter {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = convertersByRatePair[ratePair] { return cached }

        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: ratePair.sourceRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: ratePair.targetRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw AudioBridgeError(
                message: "Failed to create a \(ratePair.sourceRate) Hz to \(ratePair.targetRate) Hz converter")
        }
        // FluidAudio's AudioConverter.configure(converter:).
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let cached = CachedConverter(converter: converter)
        convertersByRatePair[ratePair] = cached
        return cached
    }

    // FluidAudio's AudioConverter.resampleAudioFile read loop, mono Float32.
    private func readSamples(of audioFile: AVAudioFile) throws -> [Float] {
        let format = audioFile.processingFormat
        let chunkSize = max(4096, Int(format.sampleRate))
        var samples: [Float] = []
        samples.reserveCapacity(Int(audioFile.length))

        while audioFile.framePosition < audioFile.length {
            let remaining = Int(audioFile.length - audioFile.framePosition)
            let framesToRead = AVAudioFrameCount(min(chunkSize, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw AudioBridgeError(message: "Failed to allocate a \(framesToRead)-frame read buffer")
            }
            try audioFile.read(into: buffer)
            if buffer.frameLength == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    // FluidAudio's AudioConverter.convertBuffer(_:to:): one pass sized for
    // the whole input, then 4096-frame passes until end of stream.
    private func convert(_ inputBuffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> [Float] {
        let outputFormat = converter.outputFormat
        let sampleRateRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let estimatedOutputFrames = AVAudioFrameCount((Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up))

        var output: [Float] = []
        output.reserveCapacity(Int(estimatedOutputFrames))

        var isInputProvided = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if isInputProvided {
                status.pointee = .endOfStream
                return nil
            }
            isInputProvided = true
            status.pointee = .haveData
            return inputBuffer
        }

        func appendPass(capacity: AVAudioFrameCount) throws -> AVAudioConverterOutputStatus {
            guard let passBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioBridgeError(message: "Failed to allocate a \(capacity)-frame resampler output buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: passBuffer, error: &conversionError, withInputFrom: inputBlock)
            guard status != .error else {
                throw AudioBridgeError(
                    message: "Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown error")")
            }
            if passBuffer.frameLength > 0, let channelData = passBuffer.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(passBuffer.frameLength)))
            }
            return status
        }

        _ = try appendPass(capacity: estimatedOutputFrames)
        while try appendPass(capacity: 4096) != .endOfStream {}
        return output
    }
}
