#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target="macos-aarch64" ;;
  Darwin-x86_64) target="macos-x86_64" ;;
  Linux-x86_64) target="linux-x86_64" ;;
  *) printf 'unsupported workload baseline target: %s-%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 2 ;;
esac

script/record_performance_artifacts.sh
python3 script/check_workload_baseline.py --directory benchmarks/workload-baselines/v1 "zig-out/performance/workloads-${target}.json"
