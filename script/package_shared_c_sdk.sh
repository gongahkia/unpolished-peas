#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
zig_exe="${ZIG_EXE:-$(command -v zig)}"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
abi_version=$(sed -n 's/^#define MINNA_SAN_ABI_VERSION \([0-9][0-9]*\)u$/\1/p' packages/c-abi/include/minna_san.h)
output="${1:-${C_SDK_SHARED_OUTPUT:-$root/zig-out/c-sdk-shared-$version}}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

[ -n "$version" ] && [ -n "$abi_version" ] || exit 1
rm -rf "$output"
mkdir -p "$output"

package_target() {
    target="$1"
    directory="$2"
    library="$3"
    prefix="$stage/$target"
    "$zig_exe" build -Dtarget="$target" -Doptimize=ReleaseFast --prefix "$prefix" c-sdk-shared
    test -f "$prefix/$directory/$library"
    mkdir -p "$output/$target/$directory"
    cp "$prefix/$directory/$library" "$output/$target/$directory/$library"
}

package_target aarch64-macos lib libminna-san.dylib
package_target x86_64-macos lib libminna-san.dylib
package_target x86_64-linux lib libminna-san.so
package_target x86_64-windows bin minna-san.dll

python3 - "$output/metadata.json" "$version" "$abi_version" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "schema_version": 1,
    "sdk_version": sys.argv[2],
    "abi_version": int(sys.argv[3]),
    "linkage": "shared",
    "targets": [
        {"triple": "aarch64-macos", "directory": "lib", "library": "libminna-san.dylib", "loader": "Mach-O arm64"},
        {"triple": "x86_64-macos", "directory": "lib", "library": "libminna-san.dylib", "loader": "Mach-O x86_64"},
        {"triple": "x86_64-linux", "directory": "lib", "library": "libminna-san.so", "loader": "ELF x86-64"},
        {"triple": "x86_64-windows", "directory": "bin", "library": "minna-san.dll", "loader": "PE32+ x86-64"},
    ],
}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
