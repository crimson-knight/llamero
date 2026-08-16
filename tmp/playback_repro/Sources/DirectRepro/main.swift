import FluidAudio
import Foundation
import ReproSupport
import Synchronization

@main
struct DirectRepro {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let presetName = arguments.first ?? "default"
        let runs = arguments.count > 1 ? Int(arguments[1]) ?? 1 : 1
        let directory = arguments.count > 2 ? URL(fileURLWithPath: arguments[2], isDirectory: true) : nil
        let skipBefore = ProcessInfo.processInfo.environment["REPRO_SKIP_BEFORE"] == "1"

        guard let preset = TtsComputeUnitPreset(cliValue: presetName) else {
            fputs("usage: direct-repro [default|all-ane|cpu-and-gpu|cpu-only] [runs] [models-dir]\n", stderr)
            Foundation.exit(64)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("llamero-playback-repro", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let probe = scratch.appendingPathComponent("probe.wav")
        let synthesis = scratch.appendingPathComponent("direct-\(preset.cliValue).wav")
        try PlaybackProbe.writeProbeWav(to: probe)

        print("MODE direct preset=\(preset.cliValue) runs=\(runs) pid=\(ProcessInfo.processInfo.processIdentifier)")
        let before = skipBefore ? true : try PlaybackProbe.assertPlaying(label: "before", url: probe)
        if skipBefore { print("SKIP playback-before") }

        let semaphore = DispatchSemaphore(value: 0)
        let synthesisError = Mutex<String?>(nil)
        Task.detached {
            do {
                let manager = KokoroAneManager(
                    directory: directory,
                    computeUnits: KokoroAneComputeUnits(preset: preset)
                )
                try await manager.initialize()
                for run in 1...max(runs, 1) {
                    let start = Date()
                    let wav = try await manager.synthesize(text: "The direct synthesis probe is running.")
                    try wav.write(to: synthesis, options: .atomic)
                    let elapsed = String(format: "%.3f", Date().timeIntervalSince(start))
                    print("SYNTH direct run=\(run) bytes=\(wav.count) elapsed=\(elapsed)")
                }
            } catch {
                synthesisError.withLock { $0 = String(describing: error) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let message = synthesisError.withLock({ $0 }) {
            throw DirectReproError(message)
        }

        let afterProbe = try PlaybackProbe.assertPlaying(label: "after-probe", url: probe)
        let afterSynthesis = try PlaybackProbe.assertPlaying(label: "after-synthesis", url: synthesis)
        let beforeStatus = before ? "PASS" : "FAIL"
        let probeStatus = afterProbe ? "PASS" : "FAIL"
        let synthesisStatus = afterSynthesis ? "PASS" : "FAIL"
        print("RESULT direct before=\(beforeStatus) afterProbe=\(probeStatus) afterSynthesis=\(synthesisStatus)")
        if !before || !afterProbe || !afterSynthesis { Foundation.exit(1) }
    }
}

private struct DirectReproError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
