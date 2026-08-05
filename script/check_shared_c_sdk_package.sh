#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
abi_version=$(sed -n 's/^#define MINNA_SAN_ABI_VERSION \([0-9][0-9]*\)u$/\1/p' "$root/packages/c-abi/include/minna_san.h")
package="${C_SDK_SHARED_PACKAGE:-$root/zig-out/c-sdk-shared-$version}"

python3 - "$package" "$version" "$abi_version" <<'PY'
import json
import pathlib
import subprocess
import sys

package = pathlib.Path(sys.argv[1])
try:
    metadata = json.loads((package / "metadata.json").read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid shared SDK package metadata: {error}")
expected = {
    "aarch64-macos": ("lib", "libminna-san.dylib", "Mach-O", "arm64"),
    "x86_64-macos": ("lib", "libminna-san.dylib", "Mach-O", "x86_64"),
    "x86_64-linux": ("lib", "libminna-san.so", "ELF", "x86-64"),
    "x86_64-windows": ("bin", "minna-san.dll", "PE32+", "x86-64"),
}
if metadata.get("schema_version") != 1 or metadata.get("sdk_version") != sys.argv[2] or metadata.get("abi_version") != int(sys.argv[3]) or metadata.get("linkage") != "shared":
    raise SystemExit("shared SDK package metadata mismatch")
targets = {entry.get("triple"): entry for entry in metadata.get("targets", []) if isinstance(entry, dict)}
if set(targets) != set(expected):
    raise SystemExit("shared SDK package target metadata mismatch")
for target, (directory, library, format_name, architecture) in expected.items():
    entry = targets[target]
    if entry.get("directory") != directory or entry.get("library") != library:
        raise SystemExit(f"shared SDK target metadata mismatch: {target}")
    artifact = package / target / directory / library
    try:
        description = subprocess.check_output(["file", str(artifact)], text=True)
    except OSError as error:
        raise SystemExit(f"missing shared SDK artifact: {error}")
    if format_name not in description or architecture not in description:
        raise SystemExit(f"shared SDK loader mismatch: {artifact}")
PY
