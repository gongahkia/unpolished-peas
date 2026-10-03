#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
version="$(sed -n 's/^    \.version = "\([0-9][0-9.]*\)",$/\1/p' "$repo/build.zig.zon" | head -n 1)"
if [ "$version" != "0.1.0" ]; then
    printf 'version consistency: expected first release version 0.1.0, found %s\n' "$version" >&2
    exit 1
fi
for path in README.md docs/guides/quickstart.md docs/guides/releases.md docs/guides/installation.md templates/starter/build.zig.zon; do
    grep -F -q -- "0.1.0" "$repo/$path" || {
        printf 'version consistency: %s does not name %s\n' "$path" "$version" >&2
        exit 1
    }
done
if rg -n --glob '!zig-out/**' --glob '!.zig-cache/**' --glob '!.zig-global-cache/**' --glob '!script/test_version_consistency.sh' 'v0\.0\.4|templates/bounce' "$repo"; then
    printf '%s\n' 'version consistency: stale release or starter path remains' >&2
    exit 1
fi
if ! grep -F -q -- 'This source-checkout template intentionally has no dependency' "$repo/templates/starter/build.zig.zon"; then
    printf '%s\n' 'version consistency: starter manifest must be explicitly unreleased before preparation' >&2
    exit 1
fi
if grep -E -q -- 'archive/refs/tags|releases/download|unpolished_peas-' "$repo/templates/starter/build.zig.zon"; then
    printf '%s\n' 'version consistency: unprepared starter manifest contains a dependency coordinate' >&2
    exit 1
fi
printf 'version consistency passed: v%s is the prepared first-release identity\n' "$version"
