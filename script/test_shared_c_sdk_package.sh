#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

ZIG_EXE="${ZIG_EXE:-$(command -v zig)}" sh script/package_shared_c_sdk.sh "$fixture/package"
C_SDK_SHARED_PACKAGE="$fixture/package" sh script/check_shared_c_sdk_package.sh
python3 -c 'import json, pathlib, sys; path = pathlib.Path(sys.argv[1]); value = json.loads(path.read_text(encoding="utf-8")); value["linkage"] = "static"; path.write_text(json.dumps(value), encoding="utf-8")' "$fixture/package/metadata.json"
if C_SDK_SHARED_PACKAGE="$fixture/package" sh script/check_shared_c_sdk_package.sh >/dev/null 2>&1; then
    exit 1
fi
