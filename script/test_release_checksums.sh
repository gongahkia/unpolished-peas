#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

sh script/package_release_artifacts.sh "$fixture/release"
RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_checksums.sh
cp "$fixture/release/SHA256SUMS" "$fixture/SHA256SUMS"
sed '1d' "$fixture/SHA256SUMS" > "$fixture/release/SHA256SUMS"
if RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_checksums.sh >/dev/null 2>&1; then
    exit 1
fi
cp "$fixture/SHA256SUMS" "$fixture/release/SHA256SUMS"
printf x >> "$fixture/release/c-sdk-headers-$version/include/minna_san.h"
if RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_checksums.sh >/dev/null 2>&1; then
    exit 1
fi
