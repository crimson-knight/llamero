import Foundation

extension Foundation.Bundle {
    static nonisolated let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("FluidAudio_FluidAudioCLI.bundle").path
        let buildPath = "/Users/crimsonknight/open_source_coding_projects/llamero/tmp/playback_repro/.build/arm64-apple-macosx/release/FluidAudio_FluidAudioCLI.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}