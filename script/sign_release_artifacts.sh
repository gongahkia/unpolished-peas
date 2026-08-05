#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
package="${RELEASE_ARTIFACT_PACKAGE:-$root/zig-out/minna-san-release-$version}"
cosign_exe="${COSIGN_EXE:-$(command -v cosign)}"
artifacts="$(mktemp)"
trap 'rm -f "$artifacts"' EXIT

RELEASE_ARTIFACT_PACKAGE="$package" sh "$root/script/check_release_checksums.sh"
find "$package" -type f ! -name '*.sigstore.json' -print | LC_ALL=C sort > "$artifacts"
while IFS= read -r artifact; do
    "$cosign_exe" sign-blob --yes --bundle "$artifact.sigstore.json" "$artifact"
    test -f "$artifact.sigstore.json"
done < "$artifacts"
