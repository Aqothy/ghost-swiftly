// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ghost-swiftly",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "GhosttyVT", targets: ["GhosttyVT"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    targets: [
        // Built by Script/build-xcframework.sh from upstream Ghostty at
        // Script/ghostty-commit.
        .binaryTarget(name: "CGhosttyVT", path: "Frameworks/ghostty-vt.xcframework"),
        .target(name: "GhosttyVT", dependencies: ["CGhosttyVT"]),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyVT"],
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(name: "GhosttyTerminalTests", dependencies: ["GhosttyTerminal"]),
        .testTarget(
            name: "GhosttyVTTests",
            dependencies: ["GhosttyVT"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
