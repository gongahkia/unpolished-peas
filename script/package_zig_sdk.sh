#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
compiler="$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)",$/\1/p' build.zig.zon)"
output="${1:-${ZIG_SDK_OUTPUT:-$root/zig-out/minna-san-zig-sdk-$version.tar.gz}}"

[ -n "$version" ] && [ -n "$compiler" ] || exit 1
mkdir -p "$(dirname "$output")"
python3 - "$root" "$output" "$version" "$compiler" <<'PY'
import gzip
import io
import json
import pathlib
import tarfile
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
version = sys.argv[3]
compiler = sys.argv[4]
prefix = f"minna-san-zig-sdk-{version}"
files = [
    root / "LICENSE",
    root / "REUSE.toml",
    root / "build.zig",
    root / "build.zig.zon",
]
for directory in (root / "licenses", root / "packages"):
    files.extend(path for path in directory.rglob("*") if path.is_file() and ".zig-cache" not in path.parts)
metadata = {
    "schema_version": 1,
    "sdk_version": version,
    "minimum_zig_version": compiler,
    "modules": ["core", "protocol", "transport", "topology", "state", "runtime", "c_abi"],
}
with output.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for source in sorted(files):
                relative = source.relative_to(root).as_posix()
                info = archive.gettarinfo(str(source), arcname=f"{prefix}/{relative}")
                info.mtime = 0
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                with source.open("rb") as data:
                    archive.addfile(info, data)
            encoded = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode() + b"\n"
            info = tarfile.TarInfo(f"{prefix}/metadata.json")
            info.size = len(encoded)
            info.mtime = 0
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(encoded))
PY
