#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

project="$tmp/project"
cd "$ROOT_DIR"
ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build new -- "$project"
cd "$project"
ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build
