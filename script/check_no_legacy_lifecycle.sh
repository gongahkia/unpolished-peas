#!/usr/bin/env bash
set -euo pipefail

if rg -n "pub const Frame|pub fn run" src/backend; then
  echo "legacy lifecycle remains" >&2
  exit 1
fi
