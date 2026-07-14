#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

project="$tmp/project"
cd "$ROOT_DIR"
ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build peas -- new "$project"
ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build peas -- check "$project"
ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build peas -- test unit "$project"
cd "$project"
ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build
test -d assets
test -d zig-out/assets
if [[ "${RUN_GENERATED_PROJECT:-0}" == "1" ]]; then
  cd "$ROOT_DIR"
  ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" SDL_AUDIODRIVER=dummy zig build peas -- run "$project" -- --frames 2
fi
