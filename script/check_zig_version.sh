#!/usr/bin/env bash
set -euo pipefail

EXPECTED="0.15.2"
ACTUAL="${1:-$(zig version)}"

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "unpolished-peas requires Zig $EXPECTED; found $ACTUAL" >&2
  exit 1
fi
