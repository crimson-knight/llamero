import AppKit
import Darwin
import Foundation
import ReproSupport
import Synchronization

private typealias BridgeCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias CreateFunction = @convention(c) (UnsafePointer<CChar>?) -> Int64
private typealias SpeakFunction = @convention(c) (
    Int64, UnsafePointer<CChar>?, BridgeCallback?, UnsafeMutableRawPointer?
) -> Int32
private typealias FreeFunction = @convention(c) (Int64) -> Void

private let printEvent: BridgeCallback = { json, _ in
    if let json { print("BRIDGE \(String(cString: json))") }
}

@main
struct BridgeRepro {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let dylibPath = arguments.first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".llamero/lib/libLlameroAudioBridge.dylib").path
        let runs = arguments.count > 1 ? Int(arguments[1]) ?? 1 : 1
        let modelsDirectory = arguments.count > 2 ? arguments[2] : nil
        let skipBefore = ProcessInfo.processInfo.environment["REPRO_SKIP_BEFORE"] == "1"
        let background = ProcessInfo.processInfo.environment["REPRO_BACKGROUND"] == "1"
        let appKitHost = ProcessInfo.processInfo.environment["REPRO_APPKIT"] == "1"
        if appKitHost {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            print("HOST AppKit initialized")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("llamero-playback-repro", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let probe = scratch.appendingPathComponent("probe.wav")
        let synthesis = scratch.appendingPathComponent("bridge.wav")
        try PlaybackProbe.writeProbeWav(to: probe)

        print("MODE bridge dylib=\(dylibPath) runs=\(runs) pid=\(ProcessInfo.processInfo.processIdentifier)")
        let before = skipBefore ? true : try PlaybackProbe.assertPlaying(label: "before", url: probe)
        if skipBefore { print("SKIP playback-before") }

        guard let library = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else {
            throw ReproError("dlopen failed: \(String(cString: dlerror()))")
        }
        defer { dlclose(library) }
        let create: CreateFunction = try loadSymbol("llamero_audio_runtime_create", from: library)
        let speak: SpeakFunction = try loadSymbol("llamero_audio_speak", from: library)
        let free: FreeFunction = try loadSymbol("llamero_audio_runtime_free", from: library)

        var config: [String: String] = [:]
        if let modelsDirectory { config["models_dir"] = modelsDirectory }
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configJson = String(decoding: configData, as: UTF8.self)
        let handle = configJson.withCString { create($0) }
        guard handle > 0 else { throw ReproError("runtime create failed: \(handle)") }
        defer { free(handle) }

        let workerInput = BridgeWorkerInput(speak: speak, handle: handle)
        for run in 1...max(runs, 1) {
            let request: [String: Any] = [
                "text": "The bridge synthesis probe is running.",
                "voice": "af_heart",
                "output_path": synthesis.path,
            ]
            let requestData = try JSONSerialization.data(withJSONObject: request)
            let requestJson = String(decoding: requestData, as: UTF8.self)
            let start = Date()
            let status: Int32
            if background {
                let semaphore = DispatchSemaphore(value: 0)
                let result = Mutex<Int32>(-1)
                Thread.detachNewThread {
                    let value = requestJson.withCString {
                        workerInput.speak(workerInput.handle, $0, printEvent, nil)
                    }
                    result.withLock { $0 = value }
                    semaphore.signal()
                }
                while semaphore.wait(timeout: .now()) == .timedOut {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                }
                status = result.withLock { $0 }
            } else {
                status = requestJson.withCString { speak(handle, $0, printEvent, nil) }
            }
            let elapsed = String(format: "%.3f", Date().timeIntervalSince(start))
            print("SYNTH bridge run=\(run) status=\(status) elapsed=\(elapsed)")
            guard status == 0 else { throw ReproError("speak failed: \(status)") }
        }

        let afterProbe = try PlaybackProbe.assertPlaying(label: "after-probe", url: probe)
        let afterSynthesis = try PlaybackProbe.assertPlaying(label: "after-synthesis", url: synthesis)
        let beforeStatus = before ? "PASS" : "FAIL"
        let probeStatus = afterProbe ? "PASS" : "FAIL"
        let synthesisStatus = afterSynthesis ? "PASS" : "FAIL"
        print("RESULT bridge before=\(beforeStatus) afterProbe=\(probeStatus) afterSynthesis=\(synthesisStatus)")
        if !before || !afterProbe || !afterSynthesis { Foundation.exit(1) }
    }

    private static func loadSymbol<T>(_ name: String, from library: UnsafeMutableRawPointer) throws -> T {
        guard let symbol = dlsym(library, name) else {
            throw ReproError("dlsym failed for \(name): \(String(cString: dlerror()))")
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private struct BridgeWorkerInput: @unchecked Sendable {
    let speak: SpeakFunction
    let handle: Int64
}

private struct ReproError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
