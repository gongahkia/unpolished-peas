#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
zig_exe="${ZIG_EXE:-$(command -v zig)}"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
minimum_zig_version="$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)",$/\1/p' build.zig.zon)"
package="${RELEASE_ARTIFACT_PACKAGE:-$root/zig-out/minna-san-release-$version}"
compiler_version="$("$zig_exe" version)"

test -f "$package/provenance.json"
python3 - "$package/provenance.json" "$package" "$version" "$minimum_zig_version" "$compiler_version" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
package = pathlib.Path(sys.argv[2])
metadata = json.loads(path.read_text(encoding="utf-8"))
files = sorted(
    entry for entry in package.rglob("*")
    if entry.is_file() and entry.name not in {"SHA256SUMS", "provenance.json"} and not entry.name.endswith(".sigstore.json")
)
artifacts = []
targets = {}
for entry in files:
    relative = entry.relative_to(package).as_posix()
    artifacts.append({"path": relative, "sha256": hashlib.sha256(entry.read_bytes()).hexdigest()})
    parts = relative.split("/")
    if len(parts) >= 3 and parts[0] in {f"c-sdk-static-{sys.argv[3]}", f"c-sdk-shared-{sys.argv[3]}"}:
        targets.setdefault(parts[1], []).append(relative)
expected = {
    "schema_version": 1,
    "sdk_version": sys.argv[3],
    "compiler": {"minimum_zig_version": sys.argv[4], "zig_version": sys.argv[5]},
    "targets": {target: targets[target] for target in sorted(targets)},
    "artifacts": artifacts,
}
for field, value in expected.items():
    if metadata.get(field) != value:
        raise SystemExit(f"invalid release provenance {field}")
source = metadata.get("source")
if not isinstance(source, dict) or not isinstance(source.get("repository"), str) or not source["repository"] or not re.fullmatch(r"[0-9a-f]{40}", source.get("commit", "")):
    raise SystemExit("invalid release provenance source")
build = metadata.get("build")
if not isinstance(build, dict) or any(not isinstance(build.get(field), str) or not build[field] for field in ("event", "ref", "run_id", "workflow_ref")):
    raise SystemExit("invalid release provenance build")
PY
