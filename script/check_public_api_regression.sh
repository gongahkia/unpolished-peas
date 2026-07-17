#!/bin/sh
set -eu

root="${PUBLIC_API_COMPATIBILITY_ROOT:-$(git rev-parse --show-toplevel)}"
manifest="$root/contracts/v1_release_contracts.sha256"
baseline="$root/contracts/v1_release_contracts.version"
metadata_dir="$root/licenses/releases"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

version="$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",/\1/p' "$root/build.zig.zon")"
baseline_version="$(tr -d '\r\n' < "$baseline")"

[ -n "$version" ] || fail "missing package version"
[ -f "$baseline" ] || fail "missing public API baseline version"
[ -f "$manifest" ] || fail "missing public API contract manifest"
[ "$baseline_version" = "$version" ] || fail "public API baseline version mismatch"
[ -f "$metadata_dir/$version.toml" ] || fail "missing release contract metadata"
grep -Fqx "release = \"$version\"" "$metadata_dir/$version.toml" || fail "release contract metadata version mismatch"
[ "$(awk '{print $2}' "$manifest")" = "contracts/v1_public_api.zig
packages/c-abi/include/minna_san.h" ] || fail "invalid public API contract manifest"
(cd "$root" && shasum -a 256 --check --status "contracts/v1_release_contracts.sha256") || fail "released public API contract changed"
