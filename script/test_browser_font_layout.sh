#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
zig build web-font-layout browser-authoring-reference -Dwith_sdl=false -j2
exec script/browser-authoring/run.sh --font "$repo/zig-out/font-layout" \
    --references "$repo/zig-out/browser-authoring-reference" \
    --browsers "${PEAS_AUTHORING_BROWSERS:-${UP_BROWSER:-chromium}}" \
    --diagnostics "${PEAS_AUTHORING_DIAGNOSTICS:-$repo/zig-out/diagnostics/font-layout/browser-authoring}"
