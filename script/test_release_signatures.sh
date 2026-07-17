#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
fake_cosign="$fixture/cosign"
identity="https://github.com/gongahkia/minna-san/.github/workflows/release-signing.yml@refs/tags/v$version"
issuer="https://token.actions.githubusercontent.com"

printf '%s\n' '#!/bin/sh' 'set -eu' 'case "$1" in' 'sign-blob)' '    test "$2" = --yes' '    test "$3" = --bundle' '    test -f "$5"' '    shasum -a 256 "$5" > "$4"' '    ;;' 'verify-blob)' '    test "$2" = --bundle' '    test -f "$3"' '    test "$4" = --certificate-identity' '    test "$5" = "$COSIGN_TEST_IDENTITY"' '    test "$6" = --certificate-oidc-issuer' '    test "$7" = "$COSIGN_TEST_ISSUER"' '    shasum -a 256 "$8" | cmp -s - "$3"' '    ;;' '*) exit 1 ;;' 'esac' > "$fake_cosign"
chmod +x "$fake_cosign"
sh script/package_release_artifacts.sh "$fixture/release"
COSIGN_EXE="$fake_cosign" RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/sign_release_artifacts.sh
COSIGN_EXE="$fake_cosign" COSIGN_CERTIFICATE_IDENTITY="$identity" COSIGN_OIDC_ISSUER="$issuer" COSIGN_TEST_IDENTITY="$identity" COSIGN_TEST_ISSUER="$issuer" RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_signatures.sh
rm "$fixture/release/SHA256SUMS.sigstore.json"
if COSIGN_EXE="$fake_cosign" COSIGN_CERTIFICATE_IDENTITY="$identity" COSIGN_OIDC_ISSUER="$issuer" COSIGN_TEST_IDENTITY="$identity" COSIGN_TEST_ISSUER="$issuer" RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_signatures.sh >/dev/null 2>&1; then
    exit 1
fi
COSIGN_EXE="$fake_cosign" RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/sign_release_artifacts.sh
printf x >> "$fixture/release/SHA256SUMS.sigstore.json"
if COSIGN_EXE="$fake_cosign" COSIGN_CERTIFICATE_IDENTITY="$identity" COSIGN_OIDC_ISSUER="$issuer" COSIGN_TEST_IDENTITY="$identity" COSIGN_TEST_ISSUER="$issuer" RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_signatures.sh >/dev/null 2>&1; then
    exit 1
fi
sh script/check_release_signing_workflow.sh
workflow="$fixture/release-signing.yml"
sed '/id-token: write/d' .github/workflows/release-signing.yml > "$workflow"
if RELEASE_SIGNING_WORKFLOW="$workflow" sh script/check_release_signing_workflow.sh >/dev/null 2>&1; then
    exit 1
fi
awk '!removed && /COSIGN_CERTIFICATE_IDENTITY/ { removed=1; next } { print }' .github/workflows/release-signing.yml > "$workflow"
if RELEASE_SIGNING_WORKFLOW="$workflow" sh script/check_release_signing_workflow.sh >/dev/null 2>&1; then
    exit 1
fi
