#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
release="$tmp/release"
global_cache="${ZIG_GLOBAL_CACHE_DIR:-$tmp/global-cache}"

mkdir "$release"
tree="$($repo/script/worktree_treeish.sh)"
git -C "$repo" archive --format=tar "$tree" | tar -x -C "$release"
# This post-v0.1 tooling is intentionally still uncommitted while it is being
# validated. Overlay only its packaged files onto a release-style archive so
# this check proves the package boundary rather than a checkout-relative path.
mkdir -p "$release/src/browser"
cp "$repo/src/browser/dev_server.py" "$release/src/browser/dev_server.py"
cp "$repo/templates/starter/build.zig" "$release/templates/starter/build.zig"
cp "$repo/dogfood/neon-siege/build.zig" "$release/dogfood/neon-siege/build.zig"

run_project() {
    local source="$1"
    local manifest="$2"
    local name
    name="$(basename -- "$source")"
    local project="$tmp/$name"
    local cache="$tmp/cache-$name"
    cp -R "$release/$source/." "$project"
    cp "$release/$manifest" "$project/build.zig.zon"
    (
        cd "$project"
        ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$cache" zig build web
        ! rg -F -q -- '/_peas/reload' zig-out/web
        ! rg -F -q -- 'EventSource' zig-out/web
        ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$cache" zig build dev-web -Ddev-web-once=true -Ddev-web-port=0
        if rg -F -q -- "$repo" .; then
            printf '%s\n' 'browser development external fixture retained a source-checkout path' >&2
            exit 1
        fi
    )
}

exercise_live_starter() {
    local project="$tmp/starter"
    local cache="$tmp/cache-starter-live"
    local log="$tmp/starter-dev-web.log"
    (
        cd "$project"
        setsid env ZIG_GLOBAL_CACHE_DIR="$global_cache" ZIG_LOCAL_CACHE_DIR="$cache" zig build dev-web -Ddev-web-port=0 >"$log" 2>&1 &
        local dev_pid=$!
        cleanup_live() {
            kill -INT -- "-$dev_pid" 2>/dev/null || true
            for _ in $(seq 1 40); do
                if ! kill -0 -- "-$dev_pid" 2>/dev/null; then break; fi
                sleep 0.05
            done
            kill -TERM -- "-$dev_pid" 2>/dev/null || true
            wait "$dev_pid" 2>/dev/null || true
        }
        trap cleanup_live EXIT HUP INT TERM
        for _ in $(seq 1 160); do
            if rg -q 'browser development server:' "$log"; then break; fi
            sleep 0.05
        done
        rg -q 'browser development server:' "$log"
        local port
        port="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+)\/.*/\1/p' "$log" | tail -n 1)"
        test -n "$port"
        curl --fail --silent --show-error "http://127.0.0.1:$port/" >/dev/null
        printf '\n' >> src/game.zig
        for _ in $(seq 1 240); do
            if rg -q 'browser build 2 succeeded' "$log"; then break; fi
            sleep 0.05
        done
        rg -q 'browser build 2 succeeded' "$log"
        curl --fail --silent --show-error "http://127.0.0.1:$port/" >/dev/null
    )
}

run_project "templates/starter" "fixtures/release-candidate-consumer/build.zig.zon"
run_project "dogfood/neon-siege" "fixtures/dogfood-release-consumer/build.zig.zon"
exercise_live_starter

printf '%s\n' 'browser development external consumers passed: starter-live,dogfood,web,dev-web,no-checkout'
