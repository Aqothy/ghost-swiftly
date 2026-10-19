#!/bin/sh
# Pins libghostty-vt to Ghostty's CI build of <commit>
# (.github/workflows/release-tip.yml, build-lib-vt-xcframework): verifies it
# against Ghostty's key (PACKAGING.md), then sets the commit and checksum in
# Package.swift and BuildInfo.swift. Ghostty publishes the signature only on
# its rolling "tip" release, so <commit> must be the current tip. Needs
# minisign. Then pin maiD's daemon to the same commit and checksum (its
# Makefile says where) and regenerate the fixture (Script/snapshot-fixture).
#
# Usage: Script/bump-ghostty.sh <full commit>
set -eu

commit=${1:?usage: Script/bump-ghostty.sh <full commit>}
root=$(cd "$(dirname "$0")/.." && pwd)
key=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

zip="$work/ghostty-vt.xcframework.zip"
curl -fsSL -o "$zip" "https://tip.files.ghostty.org/$commit/ghostty-vt.xcframework.zip"
tip=https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt.xcframework.zip
curl -fsSL -o "$work/tip.zip" "$tip"
curl -fsSL -o "$work/tip.zip.minisig" "$tip.minisig"
if ! cmp -s "$zip" "$work/tip.zip"; then
    echo "error: $commit isn't Ghostty's current tip build, whose signature is the only one published" >&2
    exit 1
fi
minisign -Vm "$zip" -x "$work/tip.zip.minisig" -P "$key"

checksum=$(swift package compute-checksum "$zip")
sed -i '' \
    -e "s|^let ghosttyCommit = .*|let ghosttyCommit = \"$commit\"|" \
    -e "s|^let ghosttyChecksum = .*|let ghosttyChecksum = \"$checksum\"|" \
    "$root/Package.swift"
sed -i '' "s|public static let commit = \".*\"|public static let commit = \"$commit\"|" \
    "$root/Sources/GhosttyVT/BuildInfo.swift"
echo "pinned Ghostty $commit (checksum $checksum)"
