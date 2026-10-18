#!/bin/sh
# Builds Frameworks/ghostty-vt.xcframework from upstream Ghostty at the commit
# in Script/ghostty-commit, unpatched. Needs zig (Ghostty's minimum_zig_version)
# and Xcode.
#
# GHOSTTY_SOURCE: a local Ghostty clone to fetch from instead of GitHub.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
commit=$(cat "$root/Script/ghostty-commit")
checkout="$root/.build/ghostty"
source=${GHOSTTY_SOURCE:-https://github.com/ghostty-org/ghostty.git}

if [ ! -d "$checkout/.git" ]; then
    git clone --quiet --no-checkout "$source" "$checkout"
fi
if ! git -C "$checkout" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$checkout" fetch --quiet "$source" "$commit"
fi
git -C "$checkout" checkout --quiet --detach "$commit"

if [ "$(git -C "$checkout" rev-parse HEAD)" != "$commit" ]; then
    echo "error: $checkout is not at $commit" >&2
    exit 1
fi
if [ -n "$(git -C "$checkout" status --porcelain --untracked-files=normal -- . ':!zig-out' ':!.zig-cache')" ]; then
    echo "error: $checkout has local changes; this package builds Ghostty unpatched" >&2
    git -C "$checkout" status --short >&2
    exit 1
fi

# libghostty-vt reports its lib version as build info, and git metadata only
# reaches it through -Dlib-version-string. Snapshot compatibility is keyed on
# GHOSTTY_BUILD_INFO_VERSION_BUILD, so stamp the full commit there, keeping
# upstream's lib version (build.zig `lib_version`).
lib_version=$(sed -n 's/^const lib_version = "\(.*\)";$/\1/p' "$checkout/build.zig")
if [ -z "$lib_version" ]; then
    echo "error: can't read lib_version from $checkout/build.zig" >&2
    exit 1
fi

rm -rf "$checkout/zig-out"
(cd "$checkout" && zig build \
    -Demit-lib-vt \
    -Demit-xcframework \
    -Doptimize=ReleaseFast \
    "-Dlib-version-string=$lib_version+$commit")

mkdir -p "$root/Frameworks"
rm -rf "$root/Frameworks/ghostty-vt.xcframework"
cp -R "$checkout/zig-out/lib/ghostty-vt.xcframework" "$root/Frameworks/"
echo "built Frameworks/ghostty-vt.xcframework at $commit ($lib_version)"
