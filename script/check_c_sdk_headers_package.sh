#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
abi_version=$(sed -n 's/^#define MINNA_SAN_ABI_VERSION \([0-9][0-9]*\)u$/\1/p' "$root/packages/c-abi/include/minna_san.h")
package="${C_SDK_HEADERS_PACKAGE:-$root/zig-out/c-sdk-headers-$version}"
zig_exe="${ZIG_EXE:-$(command -v zig)}"

python3 - "$package/metadata.json" "$version" "$abi_version" <<'PY'
import json
import pathlib
import sys

try:
    metadata = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid C SDK header metadata: {error}")
if metadata != {"schema_version": 1, "sdk_version": sys.argv[2], "abi_version": int(sys.argv[3]), "headers": ["minna_san.h", "minna_san_api.h", "minna_san_sdk_metadata.h"]}:
    raise SystemExit("C SDK header metadata mismatch")
PY
test -f "$package/include/minna_san.h"
test -f "$package/include/minna_san_api.h"
test -f "$package/include/minna_san_sdk_metadata.h"
"$zig_exe" cc -std=c11 -Wall -Wextra -Werror -c -o /dev/null -I "$package/include" "$root/contracts/fixtures/c_sdk_header_package.c"
