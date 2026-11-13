#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
zig build web-audio-lifetime -Dwith_sdl=false -j2
exec script/browser-authoring/run.sh --audio "$repo/zig-out/audio-lifetime" \
    --browsers "${PEAS_AUTHORING_BROWSERS:-${UP_BROWSER:-chromium}}" \
    --diagnostics "${PEAS_AUTHORING_DIAGNOSTICS:-$repo/zig-out/diagnostics/audio-lifetime/browser-authoring}"
