import AVFoundation
import FluidAudio
import XCTest

@testable import LlameroAudioBridge

final class AsrFileResamplerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llamero-resampler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // A 16-bit PCM WAV of `seconds` of a 440 Hz tone plus a 3.1 kHz overtone,
    // the shape of the microphone recordings the bridge transcribes.
    private func writeToneWav(
        named name: String, sampleRate: Double, channels: AVAudioChannelCount = 1, seconds: Double
    ) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                let time = Double(frame) / sampleRate
                channelData[channel][frame] = Float(0.4 * sin(2 * .pi * 440 * time) + 0.1 * sin(2 * .pi * 3100 * time))
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testMatchesFluidAudioUrlResamplingSampleForSample() throws {
        for sampleRate in [44_100.0, 48_000.0] {
            let url = try writeToneWav(named: "tone-\(Int(sampleRate)).wav", sampleRate: sampleRate, seconds: 3)

            let expected = try AudioConverter().resampleAudioFile(url)
            let cached = try XCTUnwrap(AsrFileResampler.shared.asrSamples(of: url))

            XCTAssertEqual(cached.count, expected.count, "\(sampleRate) Hz sample count")
            XCTAssertEqual(cached, expected, "\(sampleRate) Hz samples")
        }
    }

    func testReusesOneConverterPerRatePairAcrossFiles() throws {
        let resampler = AsrFileResampler()
        let first = try writeToneWav(named: "first.wav", sampleRate: 48_000, seconds: 2)
        let second = try writeToneWav(named: "second.wav", sampleRate: 48_000, seconds: 1)
        let other = try writeToneWav(named: "other.wav", sampleRate: 44_100, seconds: 1)

        let firstSamples = try XCTUnwrap(resampler.asrSamples(of: first))
        _ = try XCTUnwrap(resampler.asrSamples(of: second))
        let firstAgain = try XCTUnwrap(resampler.asrSamples(of: first))
        _ = try XCTUnwrap(resampler.asrSamples(of: other))

        // A reset converter repeats a file exactly.
        XCTAssertEqual(firstAgain, firstSamples)
        XCTAssertEqual(
            resampler.cachedRatePairs,
            [
                AsrFileResampler.RatePair(sourceRate: 48_000, targetRate: 16_000),
                AsrFileResampler.RatePair(sourceRate: 44_100, targetRate: 16_000),
            ])
    }

    func testPassesTargetRateAudioThroughWithoutAConverter() throws {
        let resampler = AsrFileResampler()
        let url = try writeToneWav(named: "asr-rate.wav", sampleRate: 16_000, seconds: 1)

        let samples = try XCTUnwrap(resampler.asrSamples(of: url))

        XCTAssertEqual(samples.count, 16_000)
        XCTAssertTrue(resampler.cachedRatePairs.isEmpty)
    }

    func testLeavesStereoAndDiskBackedLengthsToFluidAudio() throws {
        let resampler = AsrFileResampler()
        let stereo = try writeToneWav(named: "stereo.wav", sampleRate: 48_000, channels: 2, seconds: 1)
        let long = try writeToneWav(named: "long.wav", sampleRate: 48_000, seconds: 2)
        let shortThreshold = ASRConfig(streamingEnabled: true, streamingThreshold: 16_000)

        XCTAssertNil(try resampler.asrSamples(of: stereo))
        XCTAssertNil(try resampler.asrSamples(of: long, config: shortThreshold))
        XCTAssertTrue(resampler.cachedRatePairs.isEmpty)
    }
}
