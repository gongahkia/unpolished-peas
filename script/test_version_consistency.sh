#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
version="$(sed -n 's/^    \.version = "\([0-9][0-9.]*\)",$/\1/p' "$repo/build.zig.zon" | head -n 1)"
if [ -z "$version" ]; then
    printf '%s\n' 'version consistency: package version is missing' >&2
    exit 1
fi
for path in README.md docs/guides/quickstart.md docs/guides/releases.md docs/guides/installation.md templates/starter/build.zig.zon; do
    grep -F -q -- "$version" "$repo/$path" || {
        printf 'version consistency: %s does not name %s\n' "$path" "$version" >&2
        exit 1
    }
done
if rg -n --glob '!zig-out/**' --glob '!.zig-cache/**' --glob '!.zig-global-cache/**' --glob '!script/test_version_consistency.sh' 'v0\.0\.4|templates/bounce' "$repo"; then
    printf '%s\n' 'version consistency: stale release or starter path remains' >&2
    exit 1
fi
python3 - "$repo/templates/starter/build.zig.zon" "$version" <<'PY'
import pathlib
import re
import sys

manifest = pathlib.Path(sys.argv[1]).read_text()
version = sys.argv[2]
if '.dependencies = .{}' in manifest:
    if 'This source-checkout template intentionally has no dependency' not in manifest:
        raise SystemExit('version consistency: explain missing starter coordinates')
else:
    url = re.search(r'\.url = "([^"]+)"', manifest)
    package_hash = re.search(r'\.hash = "(unpolished_peas-[^"]+)"', manifest)
    allowed = [f'https://github.com/gongahkia/unpolished-peas/releases/download/{tag}/unpolished-peas-v{version}-source.tar.gz'
               for tag in (version, f'v{version}')]
    if not url or url[1] not in allowed or not package_hash or '.path =' in manifest:
        raise SystemExit('version consistency: starter URL and package hash must identify this release')
PY
printf 'version consistency passed: %s is the current release identity\n' "$version"
