#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 0 ]; then web=$(CDPATH='' cd -- "$1" && pwd); else
    (cd "$repo/fixtures/portable-conformance" && zig build web)
    web=$repo/fixtures/portable-conformance/zig-out/web
fi
cd "$repo"
exec script/browser-authoring/run.sh --consumer "$web" \
    --browsers "${PEAS_AUTHORING_BROWSERS:-${UP_BROWSER:-chromium}}" \
    --diagnostics "${PEAS_CONFORMANCE_DIAGNOSTICS:-$repo/zig-out/diagnostics/portable-conformance/browser}"
