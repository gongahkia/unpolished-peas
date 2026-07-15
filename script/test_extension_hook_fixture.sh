#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo/fixtures/extension-hook-game"
zig fmt --check build.zig src
zig build test
zig build -Deffects-hook=true test
