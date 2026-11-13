#!/usr/bin/env bash
set -euo pipefail

row="${1:?capability row required}"
case "$row" in
  macos-sdl_gpu|linux-sdl_gpu) ;;
  *) printf 'stable-core-capability: unsupported row %s\n' "$row" >&2; exit 64 ;;
esac

python3 script/capability_matrix.py --check-row "$row"
zig fmt --check build.zig src examples templates
zig build test-core-api
zig build test
zig build test-support
zig build test-scenes
zig build test-starter
zig build test-starter-template-browser
zig build test-starter-bundled-sdl
zig build test-docs
