#!/bin/sh
# Prepares release <version> locally: zips Frameworks/ghostty-vt.xcframework
# (from Script/build-xcframework.sh), points Package.swift at it as a release
# asset, then commits and tags. Pushing and uploading are left to you; the
# commands are printed at the end.
#
# Usage: Script/release.sh <version>    e.g. Script/release.sh 0.1.0
set -eu

version=${1:?usage: Script/release.sh <version>}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if [ -n "$(git status --porcelain)" ]; then
    echo "error: commit or discard your changes first" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    echo "error: tag $version exists" >&2
    exit 1
fi

# Every slice must be the pinned Ghostty, stamped by build-xcframework.sh.
commit=$(cat Script/ghostty-commit)
framework=Frameworks/ghostty-vt.xcframework
for library in "$framework"/*/*.a; do
    if ! strings "$library" | grep -q "+$commit"; then
        echo "error: $library isn't Ghostty $commit; run Script/build-xcframework.sh" >&2
        exit 1
    fi
done

asset=.build/release/ghostty-vt.xcframework.zip
mkdir -p .build/release
rm -f "$asset"
(cd Frameworks && zip -qry -X "$root/$asset" ghostty-vt.xcframework)
checksum=$(swift package compute-checksum "$asset")
url="https://github.com/Aqothy/ghost-swiftly/releases/download/$version/ghostty-vt.xcframework.zip"

sed -i '' \
    -e "s|^let releaseURL = .*|let releaseURL = \"$url\"|" \
    -e "s|^let releaseChecksum = .*|let releaseChecksum = \"$checksum\"|" \
    Package.swift
git commit -q -m "release: $version (Ghostty $(echo "$commit" | cut -c1-9))" -- Package.swift
git tag "$version"

cat <<EOF
Tagged $version with $asset (checksum $checksum).
To publish:
  git push origin main $version
  gh release create $version $asset --title $version --notes "libghostty-vt from Ghostty $commit"
EOF
