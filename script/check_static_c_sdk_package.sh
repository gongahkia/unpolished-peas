#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
abi_version=$(sed -n 's/^#define MINNA_SAN_ABI_VERSION \([0-9][0-9]*\)u$/\1/p' "$root/packages/c-abi/include/minna_san.h")
package="${C_SDK_STATIC_PACKAGE:-$root/zig-out/c-sdk-static-$version}"

python3 - "$package" "$version" "$abi_version" <<'PY'
import json
import pathlib
import sys

package = pathlib.Path(sys.argv[1])
version = sys.argv[2]
abi_version = int(sys.argv[3])
try:
    metadata = json.loads((package / "metadata.json").read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid static SDK package metadata: {error}")
expected = {
    "aarch64-macos": "libminna-san.a",
    "x86_64-macos": "libminna-san.a",
    "x86_64-linux": "libminna-san.a",
    "x86_64-windows": "minna-san.lib",
}
if metadata.get("schema_version") != 1 or metadata.get("sdk_version") != version or metadata.get("abi_version") != abi_version or metadata.get("linkage") != "static":
    raise SystemExit("static SDK package metadata mismatch")
targets = {entry.get("triple"): entry.get("library") for entry in metadata.get("targets", []) if isinstance(entry, dict)}
if targets != expected:
    raise SystemExit("static SDK package target metadata mismatch")
for target, library in expected.items():
    artifact = package / target / "lib" / library
    if not artifact.is_file() or artifact.stat().st_size == 0:
        raise SystemExit(f"missing static SDK artifact: {artifact}")
PY
