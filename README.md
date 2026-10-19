# ghost-swiftly

Native Apple terminal views on upstream
[libghostty-vt](https://github.com/ghostty-org/ghostty), with no Ghostty
patches. iOS 18.5 / macOS 15.6, Swift 6.2.

- `GhosttyVT`: libghostty-vt's terminal (parser, screen, scrollback, modes,
  snapshots, input encoders) behind a Swift actor. No UI.

## Building

libghostty-vt is built from the Ghostty commit in `Script/ghostty-commit`,
unpatched (needs zig and Xcode):

```sh
Script/build-xcframework.sh   # GHOSTTY_SOURCE=<local clone> to skip GitHub
swift test
```

`Tests/GhosttyVTTests/Fixtures` holds a snapshot from the Go binding at the
same commit; `Script/snapshot-fixture` regenerates it.

## Releasing

Packages that depend on this one download libghostty-vt from the GitHub
release; a checkout with a local build in `Frameworks/` uses that instead.

```sh
Script/build-xcframework.sh
Script/release.sh 0.1.0   # zips it, points Package.swift at the asset, commits and tags
```

Then push the tag and upload the zip with the commands it prints.
