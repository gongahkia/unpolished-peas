#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cd "$repo"
zig build extension-matrix > "$tmp/matrix.tsv"
count=0
while IFS=$'\t' read -r core package target consumer; do
    test -n "$core"
    test -n "$package"
    test -n "$consumer"
    test -f "$consumer/build.zig"
    case "$target" in
        test-ecs|test-effects|test-networking|test-sdl|test-box2d|test-services|test-ui) ;;
        *) printf 'unsupported extension target: %s\n' "$target" >&2; exit 64 ;;
    esac
    printf 'extension matrix: core=%s package=%s target=%s consumer=%s\n' "$core" "$package" "$target" "$consumer"
    zig build "$target"
    (cd "$consumer" && zig build test)
    count=$((count + 1))
done < "$tmp/matrix.tsv"
test "$count" -gt 0
