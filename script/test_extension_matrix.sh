#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cd "$repo"
zig build extension-matrix > "$tmp/matrix.tsv"
count=0
while IFS=$'\t' read -r core package target; do
    test -n "$core"
    test -n "$package"
    case "$target" in
        test-ecs|test-effects|test-networking|test-sdl|test-box2d|test-ui) ;;
        *) printf 'unsupported extension target: %s\n' "$target" >&2; exit 64 ;;
    esac
    printf 'extension matrix: core=%s package=%s target=%s\n' "$core" "$package" "$target"
    zig build "$target"
    count=$((count + 1))
done < "$tmp/matrix.tsv"
test "$count" -gt 0
