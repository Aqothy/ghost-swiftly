// swift-tools-version: 6.2
import PackageDescription

// libghostty-vt as Ghostty's CI builds it, unpatched, for every main commit
// (.github/workflows/release-tip.yml, build-lib-vt-xcframework).
// Script/bump-ghostty.sh verifies Ghostty's signature and sets these and
// BuildInfo.commit together.
let ghosttyCommit = "f54340ad77814fe319d136e5e915d6a48de8dd23"
let ghosttyChecksum = "e70bb38e45b831a4fd28c6e3be40f3a4d0cf62eeced9c0f1fd255a0e19606379"

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
