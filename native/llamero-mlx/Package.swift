// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "llamero-mlx",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic library so Crystal can dlopen it. The C ABI surface is
        // defined in Sources/LlameroMLXBridge/Bridge.swift and mirrored by
        // src/native/mlx_bridge.cr on the Crystal side.
        .library(name: "LlameroMLXBridge", type: .dynamic, targets: ["LlameroMLXBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
        // main (57 commits past the 3.31.3 tag): adds the Gemma 4 / Gemma 3n
        // quantized-attention + KV-sharing fixes needed for the larger + edge
        // models (gemma-3-4b load, gemma-4 e2b/12b, effective adapters).
        // Revisit/pin to a tagged release once one ships past 3.31.3.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        // The MLXHuggingFace macros expand to code using HubClient and
        // Tokenizers, which consumers must provide directly (mlx-swift-lm 3.x
        // decoupled itself from these).
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LlameroMLXBridge",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [
                // The bridge is plain blocking C ABI plumbing; v5 mode keeps
                // strict-concurrency checking from fighting the FFI patterns.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
