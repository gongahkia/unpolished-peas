#!/bin/sh
set -eu

[ "$#" -eq 1 ] || { printf '%s\n' 'usage: services_bootstrap_db.sh <postgresql-url>' >&2; exit 64; }
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec "$repo/script/services_migrate.sh" "$1" up
