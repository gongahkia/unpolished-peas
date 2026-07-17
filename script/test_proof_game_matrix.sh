#!/usr/bin/env bash
set -euo pipefail

game="${1:?usage: test_proof_game_matrix.sh <topdown|platformer>}"
case "$game" in
    topdown|platformer) ;;
    *) printf '%s\n' 'usage: test_proof_game_matrix.sh <topdown|platformer>' >&2; exit 64 ;;
esac

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
diagnostics="${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/proof-matrix/$game}"
scenario=setup
on_exit() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ]; then
        mkdir -p "$diagnostics"
        printf 'game=%s\nscenario=%s\nstatus=%s\n' "$game" "$scenario" "$status" > "$diagnostics/failure.log"
    fi
    exit "$status"
}
trap on_exit EXIT
export UP_DIAGNOSTICS_ROOT="$diagnostics"
cd "$repo"
project="fixtures/$game-project"
run() {
    scenario=$1
    shift
    "$@"
}

run cli-check zig build peas -- check "$project"
for selection in unit replay visual integration; do
    run "cli-test-$selection" zig build peas -- test "$selection" "$project"
done
run inspector-reload-profiler zig build test

case "$game" in
    topdown)
        run headless zig build test-topdown-scene
        run gameplay zig build test-topdown
        run desktop-smoke env SDL_AUDIODRIVER=dummy zig build smoke-topdown-sdl
        ;;
    platformer)
        run headless zig build test-platformer
        run desktop-smoke env SDL_AUDIODRIVER=dummy zig build smoke-platformer-sdl
        ;;
esac
