#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
project="$tmp/topdown-project"

cp -R "$repo/fixtures/topdown-project" "$project"
cd "$repo"
zig build peas -- check "$project"
zig build peas -- compile "$project" "$tmp/content"
test -f "$tmp/content/scenes/topdown.upscene.upc"
test -f "$tmp/content/assets/topdown.upassets.upc"
test -f "$tmp/content/maps/topdown.upmap.upc"
for selection in unit replay visual integration; do
    zig build peas -- test "$selection" "$project"
done
zig build test-topdown
zig build test-topdown-scene
if command -v xvfb-run >/dev/null; then
    xvfb-run -a env SDL_AUDIODRIVER=dummy zig build smoke-topdown-sdl
else
    env SDL_AUDIODRIVER=dummy zig build smoke-topdown-sdl
fi
