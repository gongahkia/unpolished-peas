#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target="macos-aarch64" ;;
  Darwin-x86_64) target="macos-x86_64" ;;
  Linux-x86_64) target="linux-x86_64" ;;
  *) printf 'unsupported benchmark artifact target: %s-%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 2 ;;
esac

mkdir -p zig-out/performance
zig build -Doptimize=ReleaseFast benchmark > "zig-out/performance/${target}.json"
zig build -Doptimize=ReleaseFast benchmark-proofs > "zig-out/performance/proof-games-${target}.json"
if zig build -Doptimize=ReleaseFast benchmark-workloads > "zig-out/performance/workloads-${target}.json" 2> "zig-out/performance/workloads-${target}.diagnostics.log"; then
  :
else
  status=$?
  printf 'native workload benchmark failed: diagnostics=zig-out/performance/workloads-%s.diagnostics.log\n' "$target" >&2
  exit "$status"
fi
printf 'performance artifacts recorded: target=%s\n' "$target"
