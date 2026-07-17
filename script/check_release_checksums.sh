#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
package="${RELEASE_ARTIFACT_PACKAGE:-$root/zig-out/minna-san-release-$version}"

test -f "$package/SHA256SUMS"
for artifact in \
    "c-sdk-static-$version/metadata.json" \
    "c-sdk-static-$version/aarch64-macos/lib/libminna-san.a" \
    "c-sdk-static-$version/x86_64-macos/lib/libminna-san.a" \
    "c-sdk-static-$version/x86_64-linux/lib/libminna-san.a" \
    "c-sdk-static-$version/x86_64-windows/lib/minna-san.lib" \
    "c-sdk-shared-$version/metadata.json" \
    "c-sdk-shared-$version/aarch64-macos/lib/libminna-san.dylib" \
    "c-sdk-shared-$version/x86_64-macos/lib/libminna-san.dylib" \
    "c-sdk-shared-$version/x86_64-linux/lib/libminna-san.so" \
    "c-sdk-shared-$version/x86_64-windows/bin/minna-san.dll" \
    "c-sdk-headers-$version/metadata.json" \
    "c-sdk-headers-$version/include/minna_san.h" \
    "c-sdk-headers-$version/include/minna_san_sdk_metadata.h" \
    "minna-san-zig-sdk-$version.tar.gz"; do
    test -f "$package/$artifact"
done
(
    cd "$package"
    expected="$(find . -type f ! -name SHA256SUMS ! -name '*.sigstore.json' -print | sed 's#^./##' | LC_ALL=C sort)"
    actual="$(sed -E 's/^.*  //' SHA256SUMS | LC_ALL=C sort)"
    test "$expected" = "$actual"
    shasum -a 256 --check --status SHA256SUMS
)
