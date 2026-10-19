# ghost-swiftly

Native Apple terminal views on upstream
[libghostty-vt](https://github.com/ghostty-org/ghostty), with no Ghostty
patches. iOS 18.5 / macOS 15.6, Swift 6.2.

- `GhosttyVT`: libghostty-vt's terminal (parser, screen, scrollback, modes,
  snapshots, input encoders) behind a Swift actor. No UI.
- `GhosttyTerminal`: SwiftUI, AppKit and UIKit views that draw a `Terminal`
  with a Swift port of Ghostty's Metal and CoreText renderer, and turn keys,
  pastes, mouse and touch into input for the host (`TerminalIO`).

## Building

libghostty-vt comes from Ghostty's own CI build of the commit in
`Package.swift` (`ghosttyCommit`), unpatched, which SwiftPM downloads and
checks against `ghosttyChecksum`:

```sh
swift test
```

To move to a newer Ghostty, pin its current tip build after checking
Ghostty's signature (needs minisign):

```sh
Script/bump-ghostty.sh <commit>
Script/upstream-diff.sh <commit>   # what changed in the ported sources
Script/generate-keycodes.py <ghostty checkout>
Script/generate-nerd-font-table.py <ghostty checkout>
```

`Tests/GhosttyVTTests/Fixtures` holds a snapshot from the Go binding at the
same commit; `Script/snapshot-fixture` regenerates it.

## Releasing

A release is a tag: `git tag <version>` and push it.
