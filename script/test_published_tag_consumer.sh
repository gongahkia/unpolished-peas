#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tag="${UP_RELEASE_TAG:?UP_RELEASE_TAG is required}"
case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) printf 'published consumer: expected a semver tag, found %s\n' "$tag" >&2; exit 64 ;;
esac

expected_url="https://github.com/gongahkia/unpolished-peas/archive/refs/tags/${tag}.tar.gz"
tmp="$(mktemp -d)"
consumer="$tmp/consumer"
generation_cache="$tmp/generation-cache"
verification_cache="$tmp/verification-cache"
consumer_cache="$tmp/consumer-cache"
cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        printf 'published consumer failed: tag=%s recovery=verify the public archive URL and hash, then rerun script/test_published_tag_consumer.sh\n' "$tag" >&2
    fi
    rm -rf "$tmp"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

cd "$repo"
ZIG_GLOBAL_CACHE_DIR="$generation_cache/global" ZIG_LOCAL_CACHE_DIR="$generation_cache/local" zig build peas -- new "$consumer"
manifest="$consumer/build.zig.zon"
rg -Fqx "            .url = \"$expected_url\"," "$manifest"
archive_hash="$(ZIG_GLOBAL_CACHE_DIR="$verification_cache/global" ZIG_LOCAL_CACHE_DIR="$verification_cache/local" zig fetch "$expected_url")"
case "$archive_hash" in
    unpolished_peas-*) ;;
    *) printf 'published consumer: public archive returned invalid hash for tag=%s\n' "$tag" >&2; exit 1 ;;
esac
rg -Fqx "            .hash = \"$archive_hash\"," "$manifest"
if rg -Fq '.path =' "$manifest"; then
    printf '%s\n' 'published consumer: generated manifest must use the public tag archive, not a local path' >&2
    exit 1
fi

(
    cd "$consumer"
    ZIG_GLOBAL_CACHE_DIR="$consumer_cache/global" ZIG_LOCAL_CACHE_DIR="$consumer_cache/local" zig build
)
case "$(uname -s)" in
    Linux)
        (
            cd "$consumer"
            ZIG_GLOBAL_CACHE_DIR="$consumer_cache/global" ZIG_LOCAL_CACHE_DIR="$consumer_cache/local" \
                "$repo/script/run_linux_software_gl.sh" zig build run -- --frames 2
        )
        ;;
    Darwin)
        (
            cd "$consumer"
            ZIG_GLOBAL_CACHE_DIR="$consumer_cache/global" ZIG_LOCAL_CACHE_DIR="$consumer_cache/local" \
                env SDL_AUDIODRIVER=dummy zig build run -- --frames 2
        )
        ;;
    *) printf 'published consumer: unsupported host %s\n' "$(uname -s)" >&2; exit 69 ;;
esac
printf 'published tag consumer passed: tag=%s url=%s hash=%s\n' "$tag" "$expected_url" "$archive_hash"
