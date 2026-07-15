#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cache="$(mktemp -d "$repo/fixtures/.package-release-cache.XXXXXX")"
effects_consumer="$(mktemp -d "$repo/fixtures/.package-release-effects.XXXXXX")"
physics_consumer="$(mktemp -d "$repo/fixtures/.package-release-physics.XXXXXX")"
trap 'rm -rf "$cache" "$effects_consumer" "$physics_consumer"' EXIT HUP INT TERM
cd "$repo"

zig build test-extensions
zig build test-extension-manifest
zig build test-extension-matrix
script/test_extension_matrix.sh

effects="$(zig fetch --global-cache-dir "$cache" packages/effects)"
physics="$(zig fetch --global-cache-dir "$cache" packages/physics)"
effects_archive="$cache/p/$effects"
physics_archive="$cache/p/$physics"
for path in \
    "$effects_archive/build.zig" \
    "$effects_archive/build.zig.zon" \
    "$effects_archive/build_hook.zig" \
    "$effects_archive/extension.zon" \
    "$effects_archive/src/effects.zig" \
    "$physics_archive/build.zig" \
    "$physics_archive/build.zig.zon" \
    "$physics_archive/extension.zon" \
    "$physics_archive/src/physics.zig"; do
    test -f "$path"
done
(cd "$effects_archive" && zig build --global-cache-dir "$cache" test)

rmdir "$effects_consumer" "$physics_consumer"
cp -R fixtures/effects-package "$effects_consumer"
cp -R fixtures/physics-package "$physics_consumer"
cache_name="$(basename "$cache")"
perl -0pi -e "s#\.\./\.\./packages/effects#../$cache_name/p/$effects#g" "$effects_consumer/build.zig.zon"
perl -0pi -e "s#\.\./\.\./packages/physics#../$cache_name/p/$physics#g" "$physics_consumer/build.zig.zon"
(cd "$effects_consumer" && zig build test)
(cd "$physics_consumer" && zig build test)
