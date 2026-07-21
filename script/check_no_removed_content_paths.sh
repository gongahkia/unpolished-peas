#!/usr/bin/env bash
set -euo pipefail

if find fixtures script .github -type f ! -name 'check_no_removed_content_paths.sh' -exec grep -n -i -E -- '(\.upassets|\.upmap|\.upc|contentc|\.upscene|\.tmx|\.tsx|\.ldtk|project\.up($|[^[:alnum:]_]))' {} +; then
  echo "removed content path remains" >&2
  exit 1
fi
