#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"

sh script/check_license_metadata.sh
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
sed 's/SPDX-License-Identifier = "BUSL-1.1"/SPDX-License-Identifier = "Apache-2.0"/' REUSE.toml > "$fixture"
if LICENSE_METADATA_FILE="$fixture" sh script/check_license_metadata.sh >/dev/null 2>&1; then
    exit 1
fi
