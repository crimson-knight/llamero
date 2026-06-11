// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "llamero-audio",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic library so Crystal can dlopen it. The C ABI surface is
        // defined in Sources/LlameroAudioBridge/Bridge.swift and mirrored by
        // src/native/audio_bridge.cr on the Crystal side.
        .library(name: "LlameroAudioBridge", type: .dynamic, targets: ["LlameroAudioBridge"])
    ],
    dependencies: [
        // CoreML/ANE-based Parakeet ASR + Kokoro TTS. Runs speech models on
        // the Neural Engine, leaving the GPU to the MLX LLM bridge.
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.15.2"))
    ],
    targets: [
        .target(
            name: "LlameroAudioBridge",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            swiftSettings: [
                // The bridge is plain blocking C ABI plumbing; v5 mode keeps
                // strict-concurrency checking from fighting the FFI patterns
                // (same choice as native/llamero-mlx).
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
