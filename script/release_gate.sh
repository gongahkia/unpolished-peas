#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
diagnostics="${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/release-gate}"
gate='setup'
mkdir -p "$diagnostics"
cd "$repo"

run() {
    gate=$1
    shift
    local log="$diagnostics/$gate.log"
    if "$@" >"$log" 2>&1; then
        return
    else
        local status=$?
        local failure="$diagnostics/failure.log"
        printf 'gate=%s\nstatus=%s\nlog=%s\n' "$gate" "$status" "$log" >"$failure"
        cat "$log" >&2
        printf 'release gate failed: gate=%s log=%s failure=%s\n' "$gate" "$log" "$failure" >&2
        exit "$status"
    fi
}

runtime() {
    case "$(uname -s)" in
        Linux) xvfb-run -a env SDL_AUDIODRIVER=dummy "$@" ;;
        Darwin) env SDL_AUDIODRIVER=dummy "$@" ;;
        *) printf 'release_gate.sh: unsupported host %s\n' "$(uname -s)" >&2; return 69 ;;
    esac
}

case "$(uname -s)" in
    Linux) package_script=script/test_linux_package.sh ;;
    Darwin) package_script=script/test_macos_package.sh ;;
    *) printf 'release_gate.sh: unsupported host %s\n' "$(uname -s)" >&2; exit 69 ;;
esac

run api zig build test
run api-modules zig build test-modules
run cli zig build test-peas
run cli-starter zig build test-starter
run proof-topdown runtime script/test_proof_game_matrix.sh topdown
run proof-platformer runtime script/test_proof_game_matrix.sh platformer
run services zig build test-services
run services-workspace script/test_services_workspace.sh
run services-migrations script/test_services_migrations.sh
run package-bounce "$package_script" zig-out/release-gate/packages/bounce bounce
run package-topdown "$package_script" zig-out/release-gate/packages/topdown topdown
run package-platformer "$package_script" zig-out/release-gate/packages/platformer platformer
run visual-scenes zig build test-scenes
run visual-renderer runtime env UP_RENDERER_CONFORMANCE_REQUIRE_GPU=1 zig build test-renderer-conformance
run replay zig build test-replays
run fuzz zig build test-fuzz
run performance script/check_performance_budgets.sh
printf 'release gate passed: logs=%s\n' "$diagnostics"
