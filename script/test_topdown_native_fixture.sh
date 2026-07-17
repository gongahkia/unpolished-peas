#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
project="$repo/fixtures/topdown-project"
cd "$repo"
zig build peas -- check "$project"
for selection in unit replay visual integration; do
    zig build peas -- test "$selection" "$project"
done
zig build test-topdown
if command -v xvfb-run >/dev/null; then
    xvfb-run -a env SDL_AUDIODRIVER=dummy zig build smoke-topdown-sdl
else
    env SDL_AUDIODRIVER=dummy zig build smoke-topdown-sdl
fi
