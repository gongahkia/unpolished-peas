#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
archive="${RELEASE_ARCHIVE_OUTPUT:-$root/zig-out/minna-san-release-$version.tar.gz}"
cosign_exe="${COSIGN_EXE:-$(command -v cosign)}"
identity="${COSIGN_CERTIFICATE_IDENTITY:?missing Cosign certificate identity}"
issuer="${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"

test -f "$archive" && test -f "$archive.sigstore.json"
"$cosign_exe" verify-blob --bundle "$archive.sigstore.json" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" "$archive"
