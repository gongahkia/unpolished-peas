#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cache="$(mktemp -d "$repo/fixtures/.package-release-cache.XXXXXX")"
ecs_consumer="$(mktemp -d "$repo/fixtures/.package-release-ecs.XXXXXX")"
effects_consumer="$(mktemp -d "$repo/fixtures/.package-release-effects.XXXXXX")"
networking_consumer="$(mktemp -d "$repo/fixtures/.package-release-networking.XXXXXX")"
physics_consumer="$(mktemp -d "$repo/fixtures/.package-release-physics.XXXXXX")"
ui_consumer="$(mktemp -d "$repo/fixtures/.package-release-ui.XXXXXX")"
trap 'rm -rf "$cache" "$ecs_consumer" "$effects_consumer" "$networking_consumer" "$physics_consumer" "$ui_consumer"' EXIT HUP INT TERM
cd "$repo"

zig build test-extensions
zig build test-extension-manifest
zig build test-extension-matrix
script/test_extension_matrix.sh

ecs="$(zig fetch --global-cache-dir "$cache" packages/ecs)"
effects="$(zig fetch --global-cache-dir "$cache" packages/effects)"
networking="$(zig fetch --global-cache-dir "$cache" packages/networking)"
physics="$(zig fetch --global-cache-dir "$cache" packages/physics)"
ui="$(zig fetch --global-cache-dir "$cache" packages/ui)"
ecs_archive="$cache/p/$ecs"
effects_archive="$cache/p/$effects"
networking_archive="$cache/p/$networking"
physics_archive="$cache/p/$physics"
ui_archive="$cache/p/$ui"
for path in \
    "$ecs_archive/build.zig" \
    "$ecs_archive/build.zig.zon" \
    "$ecs_archive/extension.zon" \
    "$ecs_archive/src/ecs.zig" \
    "$effects_archive/build.zig" \
    "$effects_archive/build.zig.zon" \
    "$effects_archive/build_hook.zig" \
    "$effects_archive/extension.zon" \
    "$effects_archive/src/effects.zig" \
    "$networking_archive/build.zig" \
    "$networking_archive/build.zig.zon" \
    "$networking_archive/extension.zon" \
    "$networking_archive/src/networking.zig" \
    "$physics_archive/build.zig" \
    "$physics_archive/build.zig.zon" \
    "$physics_archive/extension.zon" \
    "$physics_archive/src/physics.zig" \
    "$ui_archive/build.zig" \
    "$ui_archive/build.zig.zon" \
    "$ui_archive/extension.zon" \
    "$ui_archive/src/ui.zig"; do
    test -f "$path"
done
(cd "$ecs_archive" && zig build --global-cache-dir "$cache" test)
(cd "$effects_archive" && zig build --global-cache-dir "$cache" test)
(cd "$networking_archive" && zig build --global-cache-dir "$cache" test)

rmdir "$ecs_consumer" "$effects_consumer" "$networking_consumer" "$physics_consumer" "$ui_consumer"
cp -R fixtures/ecs-package "$ecs_consumer"
cp -R fixtures/effects-package "$effects_consumer"
cp -R fixtures/modules "$networking_consumer"
cp -R fixtures/physics-package "$physics_consumer"
cp -R fixtures/ui-package "$ui_consumer"
cache_name="$(basename "$cache")"
perl -0pi -e "s#\.\./\.\./packages/ecs#../$cache_name/p/$ecs#g" "$ecs_consumer/build.zig.zon"
perl -0pi -e "s#\.\./\.\./packages/effects#../$cache_name/p/$effects#g" "$effects_consumer/build.zig.zon"
perl -0pi -e "s#\.\./\.\./packages/networking#../$cache_name/p/$networking#g" "$networking_consumer/build.zig.zon"
perl -0pi -e "s#\.\./\.\./packages/physics#../$cache_name/p/$physics#g" "$physics_consumer/build.zig.zon"
perl -0pi -e "s#\.\./\.\./packages/ui#../$cache_name/p/$ui#g" "$ui_consumer/build.zig.zon"
(cd "$ecs_consumer" && zig build test)
(cd "$effects_consumer" && zig build test)
(cd "$networking_consumer" && zig build test)
(cd "$physics_consumer" && zig build test)
(cd "$ui_consumer" && zig build test)
