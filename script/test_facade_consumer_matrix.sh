#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

desktop="$repo/fixtures/facade-desktop"
wasm="$repo/fixtures/facade-wasm"
(cd "$desktop" && ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/desktop-cache" zig build)
(cd "$desktop" && ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/desktop-cache" zig build test)
(cd "$wasm" && ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/wasm-cache" zig build)
artifact="$wasm/zig-out/bin/facade-wasm-consumer.wasm"
test "$(od -An -tx1 -N4 "$artifact" | tr -d ' \n')" = 0061736d
printf '%s\n' 'facade-consumer-matrix passed: desktop,wasm'
