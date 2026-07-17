#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
workflow="${RELEASE_SIGNING_WORKFLOW:-$root/.github/workflows/release-signing.yml}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$workflow" ] || fail "missing release signing workflow"
for field in 'on:' '  push:' '      - "v*"' '  contents: read' '  sign:' '    runs-on: ubuntu-24.04' '      contents: read' '      id-token: write' '      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' '      - name: Install Cosign' '        uses: sigstore/cosign-installer@ba7bc0a3fef59531c69a25acd34668d6d3fe6f22' "          cosign-release: 'v3.0.6'" '      - name: Validate release tag' '        run: test "$GITHUB_REF_NAME" = "v$(tr -d '\''\r\n'\'' < contracts/v1_release_contracts.version)"' '      - name: Generate release artifact checksums' '        run: zig build release-checksums' '      - name: Sign release artifacts' '        run: sh script/sign_release_artifacts.sh' '      - name: Verify release signatures' '        run: sh script/check_release_signatures.sh' '      - name: Upload signed release artifacts' '        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain signing field: $field"
done
identity='          COSIGN_CERTIFICATE_IDENTITY: https://github.com/${{ github.repository }}/.github/workflows/release-signing.yml@${{ github.ref }}'
issuer='          COSIGN_OIDC_ISSUER: https://token.actions.githubusercontent.com'
[ "$(grep -Fcx "$identity" "$workflow")" = 2 ] || fail "workflow must verify its GitHub OIDC identity"
[ "$(grep -Fcx "$issuer" "$workflow")" = 2 ] || fail "workflow must verify its GitHub OIDC issuer"
