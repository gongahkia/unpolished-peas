#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
release="$tmp/release"
project="$tmp/lantern-leap"
global_cache="${ZIG_GLOBAL_CACHE_DIR:-$tmp/global-cache}"

mkdir "$release"
tree="$($repo/script/worktree_treeish.sh)"
git -C "$repo" archive --format=tar "$tree" | tar -x -C "$release"
# Overlay the in-progress platformer so the archive-style test proves its
# package boundary before it is part of a committed release tree.
mkdir -p "$release/dogfood/lantern-leap" "$release/fixtures/lantern-leap-release-consumer"
cp -R "$repo/dogfood/lantern-leap/." "$release/dogfood/lantern-leap"
cp "$repo/fixtures/lantern-leap-release-consumer/build.zig.zon" "$release/fixtures/lantern-leap-release-consumer/build.zig.zon"
cp -R "$release/dogfood/lantern-leap/." "$project"
cp "$release/fixtures/lantern-leap-release-consumer/build.zig.zon" "$project/build.zig.zon"

(
    cd "$project"
    ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build test
    ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build package
    ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build web
)
for path in \
    zig-out/bin/lantern-leap \
    zig-out/licenses/Basic-OFL.txt \
    zig-out/web/index.html \
    zig-out/web/lantern-leap.wasm \
    zig-out/web/bootstrap.mjs \
    zig-out/web/host.mjs \
    zig-out/web/licenses/Basic-OFL.txt; do
    test -f "$project/$path"
done
test ! -e "$project/zig-out/assets"
test ! -e "$project/zig-out/web/assets"
if rg -F -q -- "$repo" "$project"; then
    printf '%s\n' 'Lantern Leap external consumer retained a source-checkout path' >&2
    exit 1
fi
printf '%s\n' 'Lantern Leap external consumer passed: archive,test,native-package,web-package,no-checkout'
