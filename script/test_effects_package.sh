#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo/packages/effects"
zig fmt --check build.zig src
zig build test
cd "$repo/fixtures/effects-package"
zig fmt --check build.zig src
zig build test
