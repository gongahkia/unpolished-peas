#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"

sh script/check_release_license.sh
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/licenses/releases"
cp LICENSE build.zig.zon "$fixture_dir"
sed 's/change_date = "2030-07-16"/change_date = "2030-07-17"/' licenses/releases/0.1.0.toml > "$fixture_dir/licenses/releases/0.1.0.toml"
if RELEASE_LICENSE_ROOT="$fixture_dir" sh script/check_release_license.sh >/dev/null 2>&1; then
    exit 1
fi
