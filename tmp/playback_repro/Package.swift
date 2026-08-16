// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PlaybackRepro",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "direct-repro", targets: ["DirectRepro"]),
        .executable(name: "bridge-repro", targets: ["BridgeRepro"]),
    ],
    dependencies: [
        .package(path: "/Users/crimsonknight/open_source_coding_projects/FluidAudio")
    ],
    targets: [
        .target(name: "ReproSupport"),
        .executableTarget(
            name: "DirectRepro",
            dependencies: [
                "ReproSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(name: "BridgeRepro", dependencies: ["ReproSupport"]),
    ]
)
