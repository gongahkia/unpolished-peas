#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
version="$(tr -d '\r\n' < "$root/contracts/v1_release_contracts.version")"
compiler=$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)",$/\1/p' "$root/build.zig.zon")
package="${ZIG_SDK_PACKAGE:-$root/zig-out/minna-san-zig-sdk-$version.tar.gz}"

python3 - "$package" "$version" "$compiler" <<'PY'
import json
import tarfile
import sys

package, version, compiler = sys.argv[1:]
prefix = f"minna-san-zig-sdk-{version}/"
try:
    with tarfile.open(package, "r:gz") as archive:
        names = archive.getnames()
        metadata = json.load(archive.extractfile(prefix + "metadata.json"))
except (OSError, tarfile.TarError, TypeError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid Zig SDK package: {error}")
if metadata != {"schema_version": 1, "sdk_version": version, "minimum_zig_version": compiler, "modules": ["core", "protocol", "transport", "topology", "state", "runtime", "c_abi"]}:
    raise SystemExit("Zig SDK metadata mismatch")
for required in ("LICENSE", "REUSE.toml", "build.zig", "build.zig.zon", "packages/core/src/core.zig", "packages/c-abi/include/minna_san.h", "packages/c-abi/include/minna_san_api.h"):
    if prefix + required not in names:
        raise SystemExit(f"missing Zig SDK source: {required}")
if any(".zig-cache" in name for name in names):
    raise SystemExit("Zig SDK package contains a build cache")
PY
