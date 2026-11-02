#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
diagnostics=${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/renderer-three-backend}
tmp=$(mktemp -d)
trap 'find "$tmp" -depth -delete' EXIT HUP INT TERM
desktop_capture=$tmp/desktop-capture.json
browser_captures=$tmp/browser

run_desktop() {
    case "$(uname -s)" in
        Linux) xvfb-run -a env SDL_AUDIODRIVER=dummy "$@" ;;
        Darwin) env SDL_AUDIODRIVER=dummy "$@" ;;
        *) printf 'renderer three-backend: unsupported host %s\n' "$(uname -s)" >&2; return 69 ;;
    esac
}

cd "$repo"
run_desktop env UP_RENDERER_CONFORMANCE_REQUIRE_GPU=1 UP_RENDERER_CONTRACT_CAPTURE_PATH="$desktop_capture" zig build test-renderer-conformance
UP_RENDERER_CAPTURE_DIR="$browser_captures" "$repo/script/test_browser_renderer_corpus.sh"
node "$repo/script/compare_renderer_three_backend.mjs" "$desktop_capture" "$browser_captures" "$diagnostics" "$repo/src/fixtures/renderer/stable-core-v1.json"
