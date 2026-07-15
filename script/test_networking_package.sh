#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo/packages/networking"
zig fmt --check build.zig src
zig build test
cd "$repo/fixtures/modules"
zig fmt --check build.zig src
zig build test
