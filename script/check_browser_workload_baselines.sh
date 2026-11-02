#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
browser=${UP_BROWSER:-chromium}
renderers=${UP_RENDERERS:-"webgl2 webgpu"}
artifacts=${UP_PERFORMANCE_ROOT:-$repo/zig-out/performance}
case "$artifacts" in /*) ;; *) artifacts=$repo/$artifacts ;; esac

UP_BROWSER="$browser" UP_RENDERERS="$renderers" UP_PERFORMANCE_ROOT="$artifacts" "$repo/script/record_browser_workload_artifacts.sh"
for renderer in $renderers; do
    artifact="$artifacts/browser-workloads-$browser-$renderer.json"
    test -f "$artifact" || { printf 'missing browser workload artifact: %s\n' "$artifact" >&2; exit 1; }
    python3 "$repo/script/check_workload_baseline.py" --directory "$repo/benchmarks/workload-baselines/v1" "$artifact"
done
