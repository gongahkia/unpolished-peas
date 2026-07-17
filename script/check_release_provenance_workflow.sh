#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
workflow="${RELEASE_PROVENANCE_WORKFLOW:-$root/.github/workflows/release-signing.yml}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$workflow" ] || fail "missing release provenance workflow"
for field in '      attestations: write' '      artifact-metadata: write' '      - name: Verify release provenance' '        run: sh script/check_release_provenance.sh' '      - name: Attest release build provenance' '      - name: Attest release compiler and target provenance' '        uses: actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6' "          subject-path: 'zig-out/minna-san-release-*/**'" '          predicate-type: https://minna-san.dev/attestation/release-provenance/v1' "          predicate-path: 'zig-out/minna-san-release-*/provenance.json'"; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain provenance field: $field"
done
[ "$(grep -Fcx '        uses: actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6' "$workflow")" = 2 ] || fail "workflow must emit both release attestations"
[ "$(grep -Fcx "          subject-path: 'zig-out/minna-san-release-*/**'" "$workflow")" = 2 ] || fail "workflow must attest every release artifact"
