#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target="macos-aarch64" ;;
  Darwin-x86_64) target="macos-x86_64" ;;
  Linux-x86_64) target="linux-x86_64" ;;
  *)
    echo "unsupported performance baseline target: $(uname -s)-$(uname -m)" >&2
    exit 2
    ;;
esac

mkdir -p zig-out/performance
zig build -Doptimize=ReleaseFast benchmark > "zig-out/performance/${target}.json"
zig build -Doptimize=ReleaseFast benchmark-proofs > "zig-out/performance/proof-games-${target}.json"
zig build -Doptimize=ReleaseFast benchmark-workloads > "zig-out/performance/workloads-${target}.json"
python3 script/check_performance_budget.py "benchmarks/baselines/${target}.json" "zig-out/performance/${target}.json"
python3 script/check_performance_budget.py "benchmarks/proof-game-baselines/${target}.json" "zig-out/performance/proof-games-${target}.json"
python3 script/check_workload_baseline.py --directory benchmarks/workload-baselines/v1 "zig-out/performance/workloads-${target}.json"
