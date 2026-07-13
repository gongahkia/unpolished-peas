#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

project="$tmp/project"
mkdir -p "$project/src"
cp "$ROOT_DIR/fixtures/downstream/build.zig" "$project/"
cp "$ROOT_DIR/fixtures/downstream/build.zig.zon" "$project/"
cp "$ROOT_DIR/fixtures/downstream/src/main.zig" "$project/src/"
cd "$project"
ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" zig build run
