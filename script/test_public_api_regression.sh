#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/contracts" "$fixture/licenses/releases" "$fixture/packages/c-abi/include"
cp "$root/build.zig.zon" "$fixture/build.zig.zon"
cp "$root/contracts/v1_release_contracts.version" "$fixture/contracts/v1_release_contracts.version"
cp "$root/contracts/v1_release_contracts.sha256" "$fixture/contracts/v1_release_contracts.sha256"
cp "$root/contracts/v1_public_api.zig" "$fixture/contracts/v1_public_api.zig"
cp "$root/licenses/releases/0.1.0.toml" "$fixture/licenses/releases/0.1.0.toml"
cp "$root/packages/c-abi/include/minna_san.h" "$fixture/packages/c-abi/include/minna_san.h"

PUBLIC_API_COMPATIBILITY_ROOT="$fixture" sh "$root/script/check_public_api_regression.sh"
printf '\n' >> "$fixture/packages/c-abi/include/minna_san.h"
PUBLIC_API_COMPATIBILITY_ROOT="$fixture" sh "$root/script/check_public_api_regression.sh"
cp "$root/packages/c-abi/include/minna_san.h" "$fixture/packages/c-abi/include/minna_san.h"
sed 's/0.1.0/1.0.0/' "$root/build.zig.zon" > "$fixture/build.zig.zon"
sed 's/0.1.0/1.0.0/' "$root/contracts/v1_release_contracts.version" > "$fixture/contracts/v1_release_contracts.version"
sed 's/0.1.0/1.0.0/' "$root/licenses/releases/0.1.0.toml" > "$fixture/licenses/releases/1.0.0.toml"
(cd "$fixture" && shasum -a 256 contracts/v1_public_api.zig packages/c-abi/include/minna_san.h > contracts/v1_release_contracts.sha256)
PUBLIC_API_COMPATIBILITY_ROOT="$fixture" sh "$root/script/check_public_api_regression.sh"
printf '\n' >> "$fixture/packages/c-abi/include/minna_san.h"
if PUBLIC_API_COMPATIBILITY_ROOT="$fixture" sh "$root/script/check_public_api_regression.sh" >/dev/null 2>&1; then
    exit 1
fi
