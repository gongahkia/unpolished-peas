#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
sh script/check_c_api_contract.sh
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cp packages/c-abi/include/minna_san_api.h "$fixture/minna_san_api.h"
printf '\n' >> "$fixture/minna_san_api.h"
if C_API_HEADER="$fixture/minna_san_api.h" sh script/check_c_api_contract.sh >/dev/null 2>&1; then
    exit 1
fi
awk 'seen == 0 && /^pub export fn minna_san_abi_version/ { sub("pub export fn", "pub fn"); seen = 1 } { print }' packages/c-abi/src/c_abi.zig > "$fixture/c_abi.zig"
if C_API_SOURCE="$fixture/c_abi.zig" sh script/check_c_api_contract.sh >/dev/null 2>&1; then
    exit 1
fi
