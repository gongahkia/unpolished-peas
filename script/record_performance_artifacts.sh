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
printf 'performance artifacts recorded: target=%s\n' "$target"
