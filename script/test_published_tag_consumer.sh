#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tag="${UP_RELEASE_TAG:?UP_RELEASE_TAG is required}"
case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) printf 'published consumer: expected a semver tag, found %s\n' "$tag" >&2; exit 64 ;;
esac

expected_url="https://github.com/gongahkia/unpolished-peas/archive/refs/tags/${tag}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
consumer="$tmp/consumer"
cache="$tmp/cache"

cd "$repo"
ZIG_GLOBAL_CACHE_DIR="$cache/global" ZIG_LOCAL_CACHE_DIR="$cache/local" zig build peas -- new "$consumer"
manifest="$consumer/build.zig.zon"
rg -Fqx "            .url = \"$expected_url\"," "$manifest"
if rg -Fq '.path =' "$manifest"; then
    printf '%s\n' 'published consumer: generated manifest must use the public tag archive, not a local path' >&2
    exit 1
fi

(
    cd "$consumer"
    ZIG_GLOBAL_CACHE_DIR="$cache/global" ZIG_LOCAL_CACHE_DIR="$cache/local" zig build
)
case "$(uname -s)" in
    Linux)
        (
            cd "$consumer"
            ZIG_GLOBAL_CACHE_DIR="$cache/global" ZIG_LOCAL_CACHE_DIR="$cache/local" \
                xvfb-run -a env SDL_VIDEODRIVER=x11 LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy \
                zig build run -- --frames 2
        )
        ;;
    Darwin)
        (
            cd "$consumer"
            ZIG_GLOBAL_CACHE_DIR="$cache/global" ZIG_LOCAL_CACHE_DIR="$cache/local" \
                env SDL_AUDIODRIVER=dummy zig build run -- --frames 2
        )
        ;;
    *) printf 'published consumer: unsupported host %s\n' "$(uname -s)" >&2; exit 69 ;;
esac
printf 'published tag consumer passed: tag=%s url=%s\n' "$tag" "$expected_url"
