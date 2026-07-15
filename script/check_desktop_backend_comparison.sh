#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
diagnostics="${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/desktop-backend-comparison}"
mkdir -p "$diagnostics"
cd "$repo"

run() {
    local name=$1
    shift
    "$@" >"$diagnostics/$name.log" 2>&1
}

runtime() {
    case "$(uname -s)" in
        Linux) xvfb-run -a env SDL_AUDIODRIVER=dummy "$@" ;;
        Darwin) env SDL_AUDIODRIVER=dummy "$@" ;;
        *) printf 'desktop backend comparison: unsupported host %s\n' "$(uname -s)" >&2; return 69 ;;
    esac
}

run replays zig build test-replays
run sdl-gpu runtime env UP_RENDERER_CONFORMANCE_REQUIRE_GPU=1 zig build test-renderer-conformance
run opengl runtime zig build test-opengl
run visual-comparison runtime zig build test-renderer-cross-backend
run performance script/check_performance_budgets.sh
printf 'desktop backend comparison passed: logs=%s\n' "$diagnostics"
