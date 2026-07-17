#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
abi_version=$(sed -n 's/^#define MINNA_SAN_ABI_VERSION \([0-9][0-9]*\)u$/\1/p' "$root/packages/c-abi/include/minna_san.h")
output="${1:-${C_SDK_HEADERS_OUTPUT:-$root/zig-out/c-sdk-headers-$version}}"

[ -n "$version" ] && [ -n "$abi_version" ] || exit 1
rm -rf "$output"
mkdir -p "$output/include"
cp "$root/packages/c-abi/include/minna_san.h" "$output/include/minna_san.h"
printf '%s\n' '#ifndef MINNA_SAN_SDK_METADATA_H' '#define MINNA_SAN_SDK_METADATA_H' "#define MINNA_SAN_SDK_VERSION \"$version\"" "#define MINNA_SAN_SDK_ABI_VERSION ${abi_version}u" '#endif' > "$output/include/minna_san_sdk_metadata.h"
python3 - "$output/metadata.json" "$version" "$abi_version" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({"schema_version": 1, "sdk_version": sys.argv[2], "abi_version": int(sys.argv[3]), "headers": ["minna_san.h", "minna_san_sdk_metadata.h"]}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
