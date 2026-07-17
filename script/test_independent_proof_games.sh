#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

for game in bounce topdown; do
  cd "$ROOT_DIR/fixtures/${game}-project"
  ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/${game}-cache" zig build
  ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/${game}-cache" zig build test
done
