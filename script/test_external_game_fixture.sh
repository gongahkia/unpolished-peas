#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cd "$ROOT_DIR/fixtures/external-game"
ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build test
if [[ "$(uname -s)" == "Linux" ]]; then
  ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" xvfb-run -a env SDL_AUDIODRIVER=dummy zig build run
else
  ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" SDL_AUDIODRIVER=dummy zig build run
fi
