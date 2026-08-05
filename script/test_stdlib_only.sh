#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"

sh script/check_stdlib_only.sh
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
cp contracts/fixtures/third_party_import.zig.txt "$fixture_dir/fixture.zig"
if V1_SOURCE_ROOTS="$fixture_dir" sh script/check_stdlib_only.sh >/dev/null 2>&1; then
    exit 1
fi
