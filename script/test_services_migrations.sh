#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
data="$tmp/data"
socket="$tmp/socket"
log="$tmp/postgres.log"
initdb=$(command -v initdb || true)
if [ -z "$initdb" ]; then
    for candidate in /usr/lib/postgresql/*/bin/initdb; do
        if [ -x "$candidate" ]; then initdb=$candidate; break; fi
    done
fi
[ -n "$initdb" ] || { printf '%s\n' 'test_services_migrations.sh: initdb is required' >&2; exit 69; }
pg_bin=$(dirname "$initdb")
pg_ctl="$pg_bin/pg_ctl"
[ -x "$pg_ctl" ] || { printf '%s\n' 'test_services_migrations.sh: pg_ctl is required' >&2; exit 69; }
started=0
cleanup() {
    result=$?
    if [ "$result" -ne 0 ] && [ -f "$log" ]; then cat "$log" >&2; fi
    if [ "$started" -eq 1 ]; then "$pg_ctl" -D "$data" -m immediate -w stop >/dev/null 2>&1 || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir "$socket"
"$initdb" -D "$data" --no-locale --encoding=UTF8 --auth=trust >"$log"
"$pg_ctl" -D "$data" -o "-k $socket -c listen_addresses='' -p 5432" -w start >>"$log" 2>&1
started=1
database_url="postgresql:///postgres?host=$socket&port=5432"
migrate="$repo/script/services_migrate.sh"
bootstrap="$repo/script/services_bootstrap_db.sh"
"$bootstrap" "$database_url"
"$migrate" "$database_url" up
psql "$database_url" -Atq -c 'SELECT count(*) FROM service_schema_migrations' | grep -Fx '1'
if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$repo/services/migrations/0001_service_storage.up.sql" | awk '{print $1}')
else
    digest=$(shasum -a 256 "$repo/services/migrations/0001_service_storage.up.sql" | awk '{print $1}')
fi
psql "$database_url" -Atq -c "SELECT checksum FROM service_schema_migrations WHERE version = '0001_service_storage'" | grep -Fx "$digest"

psql "$database_url" -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO service_identities (id, token_hash, expires_at)
VALUES ('11111111-1111-1111-1111-111111111111', decode(repeat('11', 32), 'hex'), CURRENT_TIMESTAMP + interval '1 hour');
INSERT INTO service_identities (id, token_hash, expires_at)
VALUES ('22222222-2222-2222-2222-222222222222', decode(repeat('22', 32), 'hex'), CURRENT_TIMESTAMP + interval '1 hour');
INSERT INTO service_lobbies (id, owner_identity_id, max_members, expires_at)
VALUES ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 4, CURRENT_TIMESTAMP + interval '1 hour');
INSERT INTO service_lobby_memberships (id, lobby_id, identity_id, role)
VALUES ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'owner');
INSERT INTO service_matches (id, lobby_id)
VALUES ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333');
SQL

expect_failure() {
    if psql "$database_url" -v ON_ERROR_STOP=1 -q -c "$1" >/dev/null 2>&1; then
        printf '%s\n' 'test_services_migrations.sh: expected constraint failure' >&2
        exit 1
    fi
}

expect_failure "INSERT INTO service_sessions (id, identity_id, token_hash, expires_at) VALUES ('66666666-6666-6666-6666-666666666666', '99999999-9999-9999-9999-999999999999', decode(repeat('66', 32), 'hex'), CURRENT_TIMESTAMP + interval '1 hour')"
expect_failure "INSERT INTO service_lobbies (id, owner_identity_id, max_members, expires_at) VALUES ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', 0, CURRENT_TIMESTAMP + interval '1 hour')"
expect_failure "INSERT INTO service_lobby_memberships (id, lobby_id, identity_id, role) VALUES ('88888888-8888-8888-8888-888888888888', '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222', 'owner')"
expect_failure "INSERT INTO service_matches (id, lobby_id, status, started_at, finished_at) VALUES ('99999999-9999-9999-9999-999999999999', '33333333-3333-3333-3333-333333333333', 'completed', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP - interval '1 second')"
expect_failure "INSERT INTO service_relay_allocations (id, match_id, issued_identity_id, route_token_hash, endpoint, max_connections, max_bandwidth_kbps, expires_at) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111', decode(repeat('aa', 32), 'hex'), '127.0.0.1:48081', 0, 128, CURRENT_TIMESTAMP + interval '1 hour')"

"$migrate" "$database_url" down
psql "$database_url" -Atq -c "SELECT to_regclass('public.service_identities') IS NULL" | grep -Fx 't'
psql "$database_url" -Atq -c 'SELECT count(*) FROM service_schema_migrations' | grep -Fx '0'
