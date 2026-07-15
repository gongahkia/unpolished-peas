#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo/packages/ecs"
zig fmt --check build.zig src
zig build test
cd "$repo/fixtures/ecs-package"
zig fmt --check build.zig src
zig build test
