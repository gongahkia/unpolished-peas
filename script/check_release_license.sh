#!/bin/sh
set -eu

root="${RELEASE_LICENSE_ROOT:-$(git rev-parse --show-toplevel)}"
version="${RELEASE_LICENSE_VERSION:-$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",/\1/p' "$root/build.zig.zon")}"
metadata="$root/licenses/releases/$version.toml"
license="$root/LICENSE"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

field() {
    sed -n "s/^$1 = \"\(.*\)\"$/\1/p" "$metadata"
}

[ -n "$version" ] || fail "missing release version"
[ -f "$metadata" ] || fail "missing release metadata: $metadata"
[ -f "$license" ] || fail "missing LICENSE"

license_id="$(field license_id)"
licensor="$(field licensor)"
licensed_work="$(field licensed_work)"
release="$(field release)"
first_date="$(field first_public_distribution_date)"
change_date="$(field change_date)"
change_license="$(field change_license)"
additional_use_grant="$(field additional_use_grant)"

[ "$license_id" = "BUSL-1.1" ] || fail "release metadata must declare BUSL-1.1"
[ -n "$licensor" ] || fail "release metadata must declare a licensor"
[ "$licensed_work" = "minna-san version $version" ] || fail "licensed work must match release version"
[ "$release" = "$version" ] || fail "release metadata version mismatch"
[ "$change_license" = "Apache-2.0" ] || fail "change license must be Apache-2.0"
[ "$additional_use_grant" = "None" ] || fail "additional use grant must be None"
case "$first_date" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) fail "invalid first distribution date" ;; esac
case "$change_date" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) fail "invalid change date" ;; esac
expected_change_date="$(( ${first_date%%-*} + 4 ))${first_date#????}"
[ "$change_date" = "$expected_change_date" ] || fail "change date must be four years after first distribution"
grep -Fqx "Business Source License 1.1" "$license" || fail "LICENSE must name Business Source License 1.1"
grep -Fqx "Licensor:             $licensor" "$license" || fail "LICENSE licensor mismatch"
grep -Fqx "Licensed Work:        $licensed_work" "$license" || fail "LICENSE work mismatch"
grep -Fqx "Additional Use Grant: $additional_use_grant" "$license" || fail "LICENSE grant mismatch"
grep -Fqx "Change Date:          $change_date" "$license" || fail "LICENSE change date mismatch"
grep -Fqx "Change License:       Apache License, Version 2.0" "$license" || fail "LICENSE change license mismatch"
