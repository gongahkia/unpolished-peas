#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
zig_exe="${ZIG_EXE:-$(command -v zig)}"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
minimum_zig_version="$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)",$/\1/p' build.zig.zon)"
package="${1:-${RELEASE_ARTIFACT_PACKAGE:-$root/zig-out/minna-san-release-$version}}"
source_commit="$(git rev-parse HEAD)"
source_repository="${GITHUB_SERVER_URL:+$GITHUB_SERVER_URL/${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}}"
source_repository="${source_repository:-$(git config --get remote.origin.url)}"
compiler_version="$("$zig_exe" version)"

[ -n "$version" ] && [ -n "$minimum_zig_version" ] && [ -n "$source_repository" ] && [ -n "$compiler_version" ]
python3 - "$package/provenance.json" "$package" "$version" "$minimum_zig_version" "$source_repository" "$source_commit" "$compiler_version" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
package = pathlib.Path(sys.argv[2])
files = sorted(
    path for path in package.rglob("*")
    if path.is_file() and path.name not in {"SHA256SUMS", "provenance.json"} and not path.name.endswith(".sigstore.json")
)
artifacts = []
targets = {}
for path in files:
    relative = path.relative_to(package).as_posix()
    artifacts.append({"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    parts = relative.split("/")
    if len(parts) >= 3 and parts[0] in {f"c-sdk-static-{sys.argv[3]}", f"c-sdk-shared-{sys.argv[3]}"}:
        targets.setdefault(parts[1], []).append(relative)
metadata = {
    "schema_version": 1,
    "sdk_version": sys.argv[3],
    "source": {"repository": sys.argv[5], "commit": sys.argv[6]},
    "build": {
        "event": os.environ.get("GITHUB_EVENT_NAME", "local"),
        "ref": os.environ.get("GITHUB_REF", "local"),
        "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "workflow_ref": os.environ.get("GITHUB_WORKFLOW_REF", "local"),
    },
    "compiler": {"minimum_zig_version": sys.argv[4], "zig_version": sys.argv[7]},
    "targets": {target: targets[target] for target in sorted(targets)},
    "artifacts": artifacts,
}
output.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
