#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
package="${RELEASE_ARTIFACT_PACKAGE:-$root/zig-out/minna-san-release-$version}"
output="${RELEASE_ARCHIVE_OUTPUT:-$root/zig-out/minna-san-release-$version.tar.gz}"

test -d "$package"
rm -f "$output" "$output.sigstore.json"
tar --create --gzip --file "$output" -C "$(dirname "$package")" "$(basename "$package")"
test -f "$output"
