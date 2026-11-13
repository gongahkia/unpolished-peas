#!/usr/bin/env bash
set -euo pipefail

expected="${UP_EXPECTED_ZIG_VERSION:?UP_EXPECTED_ZIG_VERSION is required}"
case "$expected" in
  0.15.1|0.15.2) ;;
  *) printf 'unsupported compatibility Zig version: %s\n' "$expected" >&2; exit 64 ;;
esac
actual="$(zig version)"
if [[ "$actual" != "$expected" ]]; then
  printf 'expected Zig %s; found %s\n' "$expected" "$actual" >&2
  exit 1
fi
zig build -Dwith_sdl=false test
zig build -Dwith_sdl=false test-replays
script/test_independent_proof_games.sh
