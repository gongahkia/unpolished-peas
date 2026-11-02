#!/usr/bin/env bash
set -euo pipefail

if grep -R -n -E -- 'pub const Frame = struct|pub fn run\(allocator: std\.mem\.Allocator, config: Config, comptime Game: type\)' src/backend; then
  echo "legacy lifecycle remains" >&2
  exit 1
fi
