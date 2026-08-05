#!/bin/sh
set -eu

root="${LICENSE_METADATA_ROOT:-$(git rev-parse --show-toplevel)}"
metadata="${LICENSE_METADATA_FILE:-$root/REUSE.toml}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ -f "$metadata" ] || fail "missing REUSE metadata"
grep -Fqx "version = 1" "$metadata" || fail "REUSE metadata must declare version 1"
grep -Fqx 'path = ["REUSE.toml", "build.zig", "build.zig.zon", "licenses/releases/**", "packages/**", "services/**"]' "$metadata" || fail "REUSE metadata must cover release-bound paths"
grep -Fqx 'precedence = "aggregate"' "$metadata" || fail "REUSE metadata must aggregate path annotations"
grep -Fqx 'SPDX-FileCopyrightText = "2026 Gabriel Ong Zhe Mian"' "$metadata" || fail "REUSE metadata must declare copyright"
grep -Fqx 'SPDX-License-Identifier = "BUSL-1.1"' "$metadata" || fail "REUSE metadata must declare BUSL-1.1"
RELEASE_LICENSE_ROOT="$root" sh "$root/script/check_release_license.sh"
