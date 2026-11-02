#!/usr/bin/env bash
set -euo pipefail

matches=$(git ls-files -- fixtures script .github | while IFS= read -r path; do
  [ "$path" = "script/check_no_removed_content_paths.sh" ] && continue
  grep -n -i -E -- '(\.upassets|\.upmap|\.upc|contentc|\.upscene|\.tmx|\.tsx|\.ldtk|project\.up($|[^[:alnum:]_]))' "$path" || true
done)
if [ -n "$matches" ]; then
  printf '%s\n' "$matches"
  echo "removed content path remains" >&2
  exit 1
fi
