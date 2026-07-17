#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

project="$tmp/project"
release="$tmp/release"
cd "$ROOT_DIR"
mkdir "$release"
git archive --format=tar HEAD | tar -x -C "$release"
UP_STARTER_DEPENDENCY_HASH="unpolished_peas-0.0.4-test" ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build peas -- new "$project"
# Validate the generated desktop starter against a clean adjacent archive. A
# tag workflow separately validates its immutable public URL and hash.
cp "$release/fixtures/release-candidate-consumer/build.zig.zon" "$project/build.zig.zon"
ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build peas -- check "$project" --target linux
ZIG_GLOBAL_CACHE_DIR="$tmp/generator-global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/generator-local-cache" zig build peas -- test unit "$project"
cd "$project"
ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" zig build
test -d assets
test -d zig-out/assets
if [[ "${RUN_GENERATED_PROJECT:-0}" == "1" ]]; then
  cd "$ROOT_DIR"
  case "$(uname -s)" in
    Linux) ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" script/run_linux_software_gl.sh zig build peas -- run "$project" -- --frames 2 ;;
    Darwin) ZIG_GLOBAL_CACHE_DIR="$tmp/global-cache" ZIG_LOCAL_CACHE_DIR="$tmp/local-cache" SDL_AUDIODRIVER=dummy zig build peas -- run "$project" -- --frames 2 ;;
    *) printf 'test_downstream_fixture.sh: unsupported host %s\n' "$(uname -s)" >&2; exit 69 ;;
  esac
fi
