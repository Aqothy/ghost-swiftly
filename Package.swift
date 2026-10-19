// swift-tools-version: 6.2
import PackageDescription

// libghostty-vt as Ghostty's CI builds it, unpatched, for every main commit
// (.github/workflows/release-tip.yml, build-lib-vt-xcframework).
// Script/bump-ghostty.sh verifies Ghostty's signature and sets these and
// BuildInfo.commit together.
let ghosttyCommit = "81598385d608dda4946093d6d6a234d204a2f225"
let ghosttyChecksum = "06d88f611c9496f9d6e285156ddd515a6d9420383e024f279ec904a46ff1c659"

let package = Package(
    name: "ghost-swiftly",
    platforms: [.macOS("15.6"), .iOS("18.5")],
    products: [
        .library(name: "GhosttyVT", targets: ["GhosttyVT"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    targets: [
        .binaryTarget(
            name: "CGhosttyVT",
            url: "https://tip.files.ghostty.org/\(ghosttyCommit)/ghostty-vt.xcframework.zip",
            checksum: ghosttyChecksum),
        .target(name: "GhosttyVT", dependencies: ["CGhosttyVT"]),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyVT"],
            // Compiled at runtime, so building needs no Metal toolchain.
            resources: [.copy("Resources/Fonts"), .copy("Renderer/shaders.metal")]
        ),
        .testTarget(name: "GhosttyTerminalTests", dependencies: ["GhosttyTerminal"]),
        .testTarget(
            name: "GhosttyVTTests",
            dependencies: ["GhosttyVT"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
