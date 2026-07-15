#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo/packages/physics"
zig fmt --check build.zig src
zig build
cd "$repo/fixtures/physics-package"
zig fmt --check build.zig src
zig build test
