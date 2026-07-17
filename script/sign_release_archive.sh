#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
archive="${RELEASE_ARCHIVE_OUTPUT:-$root/zig-out/minna-san-release-$version.tar.gz}"
cosign_exe="${COSIGN_EXE:-$(command -v cosign)}"

test -f "$archive"
"$cosign_exe" sign-blob --yes --bundle "$archive.sigstore.json" "$archive"
test -f "$archive.sigstore.json"
