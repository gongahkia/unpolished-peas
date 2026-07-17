#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
workflow="$repo/.github/workflows/release.yml"
gate="$repo/script/release_gate.sh"

require() {
    local value=$1
    local path=$2
    rg --fixed-strings --line-regexp --quiet "$value" "$path" || {
        printf 'release validation missing: %s: %s\n' "$path" "$value" >&2
        exit 1
    }
}

require '    tags: ["v*"]' "$workflow"
require '      - run: script/test_release_validation.sh' "$workflow"
require '      - if: startsWith(github.ref, '\''refs/tags/'\'')' "$workflow"
require '        run: script/test_published_tag_consumer.sh' "$workflow"
require '      - run: zig build release-gate' "$workflow"
if rg --fixed-strings --quiet -- '--draft' "$workflow"; then
    printf '%s\n' 'release validation found a draft release command' >&2
    exit 1
fi
test "$(rg --fixed-strings --line-regexp --count '    needs: release-gate' "$workflow")" -eq 3
for command in \
    'run api-snapshot zig build test-core-api' \
    'run clean-consumer zig build test-release-candidate-clean-consumer' \
    'run proof-consumers script/test_independent_proof_games.sh' \
    'run proof-topdown runtime script/test_proof_game_matrix.sh topdown' \
    'run proof-platformer runtime script/test_proof_game_matrix.sh platformer' \
    'run package-bounce "$package_script" zig-out/release-gate/packages/bounce bounce' \
    'run package-topdown "$package_script" zig-out/release-gate/packages/topdown topdown' \
    'run package-platformer "$package_script" zig-out/release-gate/packages/platformer platformer' \
    'run diagnostics zig build test-support' \
    'run visual-scenes zig build test-scenes' \
    'run backend-comparison zig build test-desktop-backends' \
    ; do
    require "$command" "$gate"
done
if rg --fixed-strings --quiet 'check_performance_budgets.sh' "$gate"; then
    printf '%s\n' 'release validation found a performance budget gate' >&2
    exit 1
fi
printf '%s\n' 'release validation coverage passed'
