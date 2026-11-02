#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
release="$tmp/release"
project="$tmp/project"

mkdir "$release"
tree="$($repo/script/worktree_treeish.sh)"
git -C "$repo" archive --format=tar "$tree" | tar -x -C "$release"
# The dependency source archive deliberately excludes the generated starter
# manifest. A tagged checkout includes it, so simulate that checkout before
# replacing the coordinate with an adjacent immutable-archive fixture.
mkdir -p "$release/templates/starter"
cp "$repo/templates/starter/build.zig.zon" "$release/templates/starter/build.zig.zon"

(
    cd "$release"
    ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build peas -- new "$project"
)
cp "$release/fixtures/release-candidate-consumer/build.zig.zon" "$project/build.zig.zon"
(
    cd "$project"
    ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build web
)
for path in \
    zig-out/web/index.html \
    zig-out/web/unpolished-peas.wasm \
    zig-out/web/bootstrap.mjs \
    zig-out/web/host.mjs \
    zig-out/web/debug-font-v1.json \
    zig-out/web/assets/README.md; do
    test -f "$project/$path"
done
if rg -F -q -- "$repo" "$project"; then
    printf '%s\n' 'external browser fixture retained a source-checkout path' >&2
    exit 1
fi
printf '%s\n' 'downstream browser fixture passed: archive,new,web,no-checkout'
