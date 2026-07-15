#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if rg -n -i 'postgres(ql)?://|password[[:space:]]*=|UP_SERVICES_DATABASE_URL=' "$repo/services/config" "$repo/services/deploy"; then
    printf '%s\n' 'test_services_workspace.sh: deployment config must not contain secrets' >&2
    exit 1
fi
cd "$repo/services"
PKG_CONFIG_LIBDIR=/nonexistent zig build test
cd "$repo"
script/test_services_integration.sh
script/run_local_services.sh services/fixtures/local.zon --once

tmp=$(mktemp -d)
log="$tmp/services.log"
pid=''
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
env -u UP_SERVICES_DATABASE_URL script/run_local_services.sh services/fixtures/local.zon >"$log" 2>&1 &
pid=$!
port=''
attempt=0
while [ "$attempt" -lt 30 ]; do
    port=$(sed -n 's/^services: listening .*:\([0-9][0-9]*\)$/\1/p' "$log" | tail -n 1)
    [ -n "$port" ] && break
    kill -0 "$pid" >/dev/null 2>&1 || { cat "$log" >&2; exit 1; }
    attempt=$((attempt + 1))
    sleep 1
done
[ -n "$port" ] || { cat "$log" >&2; exit 1; }
curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:$port/healthz" | grep -Fx '{"status":"ok"}'
status=$(curl --silent --show-error --max-time 3 --output "$tmp/readyz.json" --write-out '%{http_code}' "http://127.0.0.1:$port/readyz")
[ "$status" = 503 ]
grep -Fx '{"database":"unavailable","relay":"unavailable"}' "$tmp/readyz.json"
