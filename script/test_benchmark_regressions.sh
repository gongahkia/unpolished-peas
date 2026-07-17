#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
zig_exe="${ZIG_EXE:-$(command -v zig)}"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

"$zig_exe" build benchmark-authoritative -Doptimize=ReleaseFast > "$fixture/authoritative.json"
"$zig_exe" build benchmark-sharded-p2p -Doptimize=ReleaseFast > "$fixture/sharded.json"
"$zig_exe" build benchmark-topology-faults -Doptimize=ReleaseFast > "$fixture/topology_faults.json"
"$zig_exe" build benchmark-throughput -Doptimize=ReleaseFast > "$fixture/throughput.json"
"$zig_exe" build benchmark-memory -Doptimize=ReleaseFast > "$fixture/memory.json"
BENCHMARK_RESULTS_DIR="$fixture" sh script/check_benchmark_regressions.sh
python3 -c 'import json, pathlib, sys; path = pathlib.Path(sys.argv[1]); value = json.loads(path.read_text(encoding="utf-8")); value["throughput_bytes_per_second"] = 0; path.write_text(json.dumps(value), encoding="utf-8")' "$fixture/throughput.json"
if BENCHMARK_RESULTS_DIR="$fixture" sh script/check_benchmark_regressions.sh >/dev/null 2>&1; then
    exit 1
fi
