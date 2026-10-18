// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ghost-swiftly",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "GhosttyVT", targets: ["GhosttyVT"]),
    ],
    targets: [
        // Built by Script/build-xcframework.sh from upstream Ghostty at
        // Script/ghostty-commit.
        .binaryTarget(name: "CGhosttyVT", path: "Frameworks/ghostty-vt.xcframework"),
        .target(name: "GhosttyVT", dependencies: ["CGhosttyVT"]),
        .testTarget(
            name: "GhosttyVTTests",
            dependencies: ["GhosttyVT"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
