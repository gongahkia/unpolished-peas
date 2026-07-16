#!/usr/bin/env bash
set -euo pipefail

if rg -n -i --glob '!check_no_removed_content_paths.sh' '(\.upassets|\.upmap|\.upc|contentc|\.upscene|\.tmx|\.tsx|\.ldtk|project\.up($|[^[:alnum:]_]))' fixtures script .github; then
  echo "removed content path remains" >&2
  exit 1
fi
