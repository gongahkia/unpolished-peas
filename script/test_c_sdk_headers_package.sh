#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

ZIG_EXE="${ZIG_EXE:-$(command -v zig)}" sh script/package_c_sdk_headers.sh "$fixture/package"
C_SDK_HEADERS_PACKAGE="$fixture/package" sh script/check_c_sdk_headers_package.sh
rm "$fixture/package/include/minna_san_sdk_metadata.h"
if C_SDK_HEADERS_PACKAGE="$fixture/package" sh script/check_c_sdk_headers_package.sh >/dev/null 2>&1; then
    exit 1
fi
