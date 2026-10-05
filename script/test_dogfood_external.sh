#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
release="$tmp/release"
project="$tmp/neon-siege"
global_cache="${ZIG_GLOBAL_CACHE_DIR:-$tmp/global-cache}"

mkdir "$release"
tree="$($repo/script/worktree_treeish.sh)"
git -C "$repo" archive --format=tar "$tree" | tar -x -C "$release"
cp -R "$release/dogfood/neon-siege/." "$project"
# The checked-in dogfood manifest points at its package-root checkout. Replace
# only that coordinate with an adjacent archive fixture to prove the source,
# build, native package, and browser package need no Peas checkout paths.
cp "$release/fixtures/dogfood-release-consumer/build.zig.zon" "$project/build.zig.zon"

(
    cd "$project"
    ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build test
    ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build package
    ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build web
)
for path in \
    zig-out/bin/neon-siege \
    zig-out/licenses/Basic-OFL.txt \
    zig-out/web/index.html \
    zig-out/web/neon-siege.wasm \
    zig-out/web/bootstrap.mjs \
    zig-out/web/host.mjs \
    zig-out/web/licenses/Basic-OFL.txt; do
    test -f "$project/$path"
done
test ! -e "$project/zig-out/assets"
test ! -e "$project/zig-out/web/assets"
if rg -F -q -- "$repo" "$project"; then
    printf '%s\n' 'dogfood external consumer retained a source-checkout path' >&2
    exit 1
fi
printf '%s\n' 'dogfood external consumer passed: archive,test,native-package,web-package,no-checkout'
