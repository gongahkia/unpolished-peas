#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
python3 "$repo/script/test_starter_generation.py" release
