#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
output="${1:-${RELEASE_ARTIFACT_OUTPUT:-$root/zig-out/minna-san-release-$version}}"

rm -rf "$output"
mkdir -p "$output"
sh script/package_static_c_sdk.sh "$output/c-sdk-static-$version"
sh script/package_shared_c_sdk.sh "$output/c-sdk-shared-$version"
sh script/package_c_sdk_headers.sh "$output/c-sdk-headers-$version"
sh script/package_zig_sdk.sh "$output/minna-san-zig-sdk-$version.tar.gz"
(
    cd "$output"
    find . -type f ! -name SHA256SUMS -print | sed 's#^./##' | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done > SHA256SUMS
)
