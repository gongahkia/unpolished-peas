#!/bin/sh
set -eu

usage() {
    printf '%s\n' 'usage: services_migrate.sh <postgresql-url> [up|down]' >&2
    exit 64
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
database_url=$1
mode=up
if [ "$#" -eq 2 ]; then mode=$2; fi
case "$mode" in up|down) ;; *) usage ;; esac

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
migrations_dir="$repo/services/migrations"
psql_cmd=${PSQL:-psql}
command -v "$psql_cmd" >/dev/null 2>&1 || { printf '%s\n' 'services_migrate.sh: psql is required' >&2; exit 69; }

"$psql_cmd" "$database_url" -v ON_ERROR_STOP=1 -q -c '
CREATE TABLE IF NOT EXISTS service_schema_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK (length(checksum) = 64),
    applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);'

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

if [ "$mode" = up ]; then
    for migration in "$migrations_dir"/*.up.sql; do
        [ -f "$migration" ] || continue
        filename=$(basename "$migration")
        version=$(printf '%s' "$filename" | sed 's/\.up\.sql$//')
        digest=$(checksum "$migration")
        recorded=$("$psql_cmd" "$database_url" -Atq -c "SELECT checksum FROM service_schema_migrations WHERE version = '$version'")
        if [ -n "$recorded" ]; then
            [ "$recorded" = "$digest" ] || { printf '%s\n' "services_migrate.sh: checksum mismatch for $version" >&2; exit 65; }
            continue
        fi
        "$psql_cmd" "$database_url" -v ON_ERROR_STOP=1 -v migration_version="$version" -v migration_checksum="$digest" -f "$migration"
    done
    exit 0
fi

version=$("$psql_cmd" "$database_url" -Atq -c 'SELECT version FROM service_schema_migrations ORDER BY applied_at DESC, version DESC LIMIT 1')
[ -n "$version" ] || exit 0
migration="$migrations_dir/$version.down.sql"
[ -f "$migration" ] || { printf '%s\n' "services_migrate.sh: missing rollback for $version" >&2; exit 66; }
"$psql_cmd" "$database_url" -v ON_ERROR_STOP=1 -v migration_version="$version" -f "$migration"
