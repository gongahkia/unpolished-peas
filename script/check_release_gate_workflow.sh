#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
workflow="${RELEASE_GATE_WORKFLOW:-$root/.github/workflows/release-signing.yml}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$workflow" ] || fail "missing release gate workflow"
for field in '  gate:' '    runs-on: ubuntu-24.04' '      contents: read' '      - name: Gate released API compatibility' '        run: zig build public-api-regression && zig build compatibility-contract && zig build c-header-contract' '      - name: Gate fuzz and lifecycle coverage' '        run: zig build test' '      - name: Gate deterministic NAT matrix' '        run: zig build reference-test' '      - name: Gate STUN TURN integration' '        run: zig build stun-turn-interop' '      - name: Gate 1,000-peer benchmark regressions' '        run: zig build benchmark-regression' '  sign:' '    needs: gate' '  publish:' '    needs: [gate, sign]' '      contents: write' '      - name: Download signed release artifacts' '        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c' '      - name: Locate signed release archive' '          echo "RELEASE_ARCHIVE=$archive" >> "$GITHUB_ENV"' '      - name: Publish release' '        run: gh release create "$GITHUB_REF_NAME" "$RELEASE_ARCHIVE" "$RELEASE_ARCHIVE.sigstore.json#minna-san-release-${GITHUB_REF_NAME#v}.tar.gz.sigstore.json" --generate-notes --title "minna-san ${GITHUB_REF_NAME#v}" --verify-tag'; do
    grep -Fqx "$field" "$workflow" || fail "workflow must retain release gate field: $field"
done
[ "$(grep -Fcx '      contents: read' "$workflow")" = 2 ] || fail "only gate and signing jobs may read contents"
[ "$(grep -Fcx '      contents: write' "$workflow")" = 1 ] || fail "only publication may write contents"
grep -Fqx '          GH_TOKEN: ${{ github.token }}' "$workflow" || fail "workflow must publish with the job token"
