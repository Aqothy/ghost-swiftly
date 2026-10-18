#!/bin/sh
# Prints the upstream Ghostty diff of every source file this package ports,
# from the commit each port records ("Ported from ghostty <path> @ <commit>")
# to <new-commit>, to review on a Ghostty bump.
#
#   Script/upstream-diff.sh <new-commit>
#
# Uses the checkout Script/build-xcframework.sh made in .build/ghostty.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
new=${1:?usage: Script/upstream-diff.sh <new-commit>}
checkout="$root/.build/ghostty"
source=${GHOSTTY_SOURCE:-https://github.com/ghostty-org/ghostty.git}

if [ ! -d "$checkout/.git" ]; then
    git clone --quiet --no-checkout "$source" "$checkout"
fi
if ! git -C "$checkout" cat-file -e "$new^{commit}" 2>/dev/null; then
    git -C "$checkout" fetch --quiet "$source" "$new"
fi

grep -rhoE 'Ported from ghostty [^ ]+ @ [0-9a-f]+' "$root/Sources" |
    sed -E 's/Ported from ghostty ([^ ]+) @ ([0-9a-f]+)/\2 \1/' |
    sort -u |
    while read -r commit path; do
        git -C "$checkout" diff --stat --exit-code "$commit" "$new" -- "$path" >/dev/null && continue
        echo "=== $path ($commit..$new)"
        git -C "$checkout" diff "$commit" "$new" -- "$path"
    done
