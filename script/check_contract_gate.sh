#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
workflow="${CONTRACT_GATE_WORKFLOW:-$root/.github/workflows/v1-contract.yml}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$workflow" ] || fail "missing v1 contract workflow"
grep -Fqx '  pull_request:' "$workflow" || fail "workflow must run on pull requests"
if grep -Fq 'pull_request_target:' "$workflow"; then
    fail "workflow must not use pull_request_target"
fi
grep -Fqx '  contents: read' "$workflow" || fail "workflow must use read-only contents permission"
grep -Fqx '      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' "$workflow" || fail "workflow must pin checkout"
grep -Fqx '      - name: Install Zig 0.15.2' "$workflow" || fail "workflow must install Zig 0.15.2"
grep -Fqx '          echo '\''02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239  zig.tar.xz'\'' | sha256sum --check --status' "$workflow" || fail "workflow must verify the Zig archive"
for command in 'zig build contract' 'zig build workspace-graph' 'zig build api-contract' 'zig build license-metadata' 'zig build quality' 'zig build dependency-policy'; do
    grep -Fqx "        run: $command" "$workflow" || fail "workflow must run $command"
done
