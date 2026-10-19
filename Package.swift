// swift-tools-version: 6.2
import Foundation
import PackageDescription

// libghostty-vt as published with this release; Script/release.sh sets both.
let releaseURL = "https://github.com/Aqothy/ghost-swiftly/releases/download/unreleased/ghostty-vt.xcframework.zip"
let releaseChecksum = "unreleased"

// Script/build-xcframework.sh builds it into Frameworks/ from upstream Ghostty
// at Script/ghostty-commit. A checkout without that build, as when another
// package depends on this one, downloads the release's.
let localXCFramework = "Frameworks/ghostty-vt.xcframework"
let libghosttyVT: Target =
    FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\(localXCFramework)")
    ? .binaryTarget(name: "CGhosttyVT", path: localXCFramework)
    : .binaryTarget(name: "CGhosttyVT", url: releaseURL, checksum: releaseChecksum)

let package = Package(
    name: "ghost-swiftly",
    platforms: [.macOS("15.6"), .iOS("18.5")],
    products: [
        .library(name: "GhosttyVT", targets: ["GhosttyVT"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    targets: [
        libghosttyVT,
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
