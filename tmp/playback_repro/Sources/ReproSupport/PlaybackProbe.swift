import AVFoundation
import Foundation

public enum PlaybackProbe {
    /// Writes a quiet two-second tone. The exact same file is used before and
    /// after synthesis so model output and WAV encoding cannot affect the test.
    public static func writeProbeWav(to url: URL) throws {
        let sampleRate: UInt32 = 24_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frameCount = Int(sampleRate) * 2
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = UInt32(frameCount * bytesPerSample)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36) + dataSize, to: &data)
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channelCount, to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * UInt32(channelCount) * UInt32(bytesPerSample), to: &data)
        append(channelCount * UInt16(bytesPerSample), to: &data)
        append(bitsPerSample, to: &data)
        data.append("data".data(using: .ascii)!)
        append(dataSize, to: &data)

        for frame in 0..<frameCount {
            let phase = 2.0 * Double.pi * 220.0 * Double(frame) / Double(sampleRate)
            let sample = Int16(sin(phase) * 2_000.0)
            append(sample, to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    public static func assertPlaying(label: String, url: URL, after delay: TimeInterval = 0.3) throws -> Bool {
        let player = try AVAudioPlayer(contentsOf: url)
        let prepared = player.prepareToPlay()
        let started = player.play()
        let duration = String(format: "%.3f", player.duration)
        print(
            "PLAYBACK \(label) start prepared=\(prepared) play=\(started) "
                + "isPlaying=\(player.isPlaying) duration=\(duration) mainThread=\(Thread.isMainThread)"
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: delay))
        let passed = player.isPlaying && player.currentTime >= delay * 0.5
        let status = passed ? "PASS" : "FAIL"
        let currentTime = String(format: "%.3f", player.currentTime)
        print(
            "\(status) playback-\(label) after_ms=\(Int(delay * 1_000)) "
                + "isPlaying=\(player.isPlaying) currentTime=\(currentTime)"
        )
        player.stop()
        return passed
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
