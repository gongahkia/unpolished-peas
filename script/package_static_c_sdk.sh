#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
zig_exe="${ZIG_EXE:-$(command -v zig)}"
version_file="contracts/v1_release_contracts.version"
version="$(tr -d '\r\n' < "$version_file")"
abi_version=$(sed -n 's/^#define MINNA_SAN_ABI_VERSION \([0-9][0-9]*\)u$/\1/p' packages/c-abi/include/minna_san.h)
output="${1:-${C_SDK_STATIC_OUTPUT:-$root/zig-out/c-sdk-static-$version}}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

case "$version" in
    ''|*[!0-9.]*|.*|*.)
        printf '%s\n' "invalid SDK version" >&2
        exit 1
        ;;
esac
[ -n "$abi_version" ] || {
    printf '%s\n' "missing C ABI version" >&2
    exit 1
}
rm -rf "$output"
mkdir -p "$output"

package_target() {
    target="$1"
    library="$2"
    destination="$output/$target/lib"
    prefix="$stage/$target"
    "$zig_exe" build -Dtarget="$target" -Doptimize=ReleaseFast --prefix "$prefix" c-sdk-static
    test -f "$prefix/lib/$library"
    mkdir -p "$destination"
    cp "$prefix/lib/$library" "$destination/$library"
}

package_target aarch64-macos libminna-san.a
package_target x86_64-macos libminna-san.a
package_target x86_64-linux libminna-san.a
package_target x86_64-windows minna-san.lib

python3 - "$output/metadata.json" "$version" "$abi_version" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
metadata = {
    "schema_version": 1,
    "sdk_version": sys.argv[2],
    "abi_version": int(sys.argv[3]),
    "linkage": "static",
    "targets": [
        {"triple": "aarch64-macos", "library": "libminna-san.a"},
        {"triple": "x86_64-macos", "library": "libminna-san.a"},
        {"triple": "x86_64-linux", "library": "libminna-san.a"},
        {"triple": "x86_64-windows", "library": "minna-san.lib"},
    ],
}
path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
