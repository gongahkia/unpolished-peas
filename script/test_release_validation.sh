#!/usr/bin/env bash
set -euo pipefail

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
workflow="$repo/.github/workflows/release.yml"
nightly="$repo/.github/workflows/nightly.yml"
pull_request="$repo/.github/workflows/toolchain.yml"
gate="$repo/script/release_gate.sh"
published_consumer="$repo/script/test_published_tag_consumer.sh"

require() {
    local value=$1
    local path=$2
    grep -F -x -q -- "$value" "$path" || {
        printf 'release validation missing: %s: %s\n' "$path" "$value" >&2
        exit 1
    }
}

require '    tags: ["v*"]' "$workflow"
require '      - run: script/test_release_validation.sh' "$workflow"
require '      - if: startsWith(github.ref, '\''refs/tags/'\'')' "$workflow"
require '        run: script/test_published_tag_consumer.sh' "$workflow"
require '      - run: zig build release-gate' "$workflow"
require 'templates/bounce/build.zig.zon export-ignore' "$repo/.gitattributes"
require 'curl --fail --location --silent --show-error "$expected_url" --output "$release_archive"' "$published_consumer"
require '    git clone --depth 1 --branch "$tag" "$repo_url"' "$published_consumer"
require '    ZIG_GLOBAL_CACHE_DIR="$generation_cache/global" ZIG_LOCAL_CACHE_DIR="$generation_cache/local" zig build new -- "$consumer"' "$published_consumer"
grep -F -q -- 'zig build run -- --frames 2' "$published_consumer" || {
    printf '%s\n' 'release validation missing published consumer frame smoke' >&2
    exit 1
}
if git archive --format=tar HEAD | tar -tf - | grep -F -x -q -- 'templates/bounce/build.zig.zon'; then
    printf '%s\n' 'release validation found generated manifest in source archive' >&2
    exit 1
fi
if grep -F -q -- '--draft' "$workflow"; then
    printf '%s\n' 'release validation found a draft release command' >&2
    exit 1
fi
test "$(grep -F -x -c -- '    needs: release-gate' "$workflow")" -eq 3
for command in \
    'run api-snapshot zig build test-core-api' \
    'run clean-consumer zig build test-release-candidate-clean-consumer' \
    'run proof-consumers script/test_independent_proof_games.sh' \
    'run proof-topdown runtime script/test_proof_game_matrix.sh topdown' \
    'run proof-puzzle runtime script/test_proof_game_matrix.sh puzzle' \
    'run proof-platformer runtime script/test_proof_game_matrix.sh platformer' \
    'run package-bounce "$package_script" zig-out/release-gate/packages/bounce bounce' \
    'run package-topdown "$package_script" zig-out/release-gate/packages/topdown topdown' \
    'run package-puzzle "$package_script" zig-out/release-gate/packages/puzzle puzzle' \
    'run package-platformer "$package_script" zig-out/release-gate/packages/platformer platformer' \
    'run diagnostics zig build test-support' \
    'run visual-scenes zig build test-scenes' \
    'run backend-comparison zig build test-desktop-backends' \
    ; do
    require "$command" "$gate"
done
if grep -F -q -- 'check_performance_budgets.sh' "$gate"; then
    printf '%s\n' 'release validation found a performance budget gate' >&2
    exit 1
fi
for performance_workflow in "$nightly" "$workflow"; do
    require "      - if: matrix.id == 'macos-sdl_gpu' || matrix.id == 'linux-sdl_gpu'" "$performance_workflow"
    require '        run: script/check_workload_performance.sh' "$performance_workflow"
    require "      - if: matrix.id == 'windows-sdl_gpu'" "$performance_workflow"
    require '        shell: pwsh' "$performance_workflow"
    require '        run: script/check_workload_performance.ps1' "$performance_workflow"
done
require '            zig-out/performance/**' "$workflow"
if grep -F -q -- 'check_workload_performance' "$pull_request"; then
    printf '%s\n' 'release validation found a workload performance gate in pull-request CI' >&2
    exit 1
fi
printf '%s\n' 'release and performance validation coverage passed'
