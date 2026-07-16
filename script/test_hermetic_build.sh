#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"

cache_dir="$(mktemp -d)"
trap 'rm -rf "$cache_dir"' EXIT
zig_exe="$(command -v zig)"
env -i ZIG_LOCAL_CACHE_DIR="$cache_dir/local" ZIG_GLOBAL_CACHE_DIR="$cache_dir/global" "$zig_exe" build test --cache-dir "$cache_dir/local" --global-cache-dir "$cache_dir/global" --summary all
