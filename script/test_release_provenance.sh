#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
version="$(tr -d '\r\n' < contracts/v1_release_contracts.version)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

sh script/package_release_artifacts.sh "$fixture/release"
RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_provenance.sh
cp "$fixture/release/provenance.json" "$fixture/provenance.json"
python3 - "$fixture/release/provenance.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
metadata = json.loads(path.read_text(encoding="utf-8"))
metadata["compiler"]["zig_version"] = "invalid"
path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_provenance.sh >/dev/null 2>&1; then
    exit 1
fi
cp "$fixture/provenance.json" "$fixture/release/provenance.json"
printf x >> "$fixture/release/c-sdk-headers-$version/include/minna_san.h"
if RELEASE_ARTIFACT_PACKAGE="$fixture/release" sh script/check_release_provenance.sh >/dev/null 2>&1; then
    exit 1
fi
sh script/check_release_provenance_workflow.sh
workflow="$fixture/release-signing.yml"
sed '/attestations: write/d' .github/workflows/release-signing.yml > "$workflow"
if RELEASE_PROVENANCE_WORKFLOW="$workflow" sh script/check_release_provenance_workflow.sh >/dev/null 2>&1; then
    exit 1
fi
