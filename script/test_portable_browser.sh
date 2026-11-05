#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
session=peas-portable-conformance-$$
pw=$repo/script/playwright_cli.sh
diagnostics=${PEAS_CONFORMANCE_DIAGNOSTICS:-$repo/zig-out/diagnostics/portable-conformance/browser}
cleanup() {
    mkdir -p "$diagnostics"
    cp "$tmp"/*.log "$tmp"/*.png "$diagnostics/" 2>/dev/null || true
    "$pw" -s="$session" close >/dev/null 2>&1 || true
    if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
if [ "$#" -gt 0 ]; then web=$1; else
    (cd "$repo/fixtures/portable-conformance" && zig build web)
    web=$repo/fixtures/portable-conformance/zig-out/web
fi
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$web" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open "http://127.0.0.1:$port/?renderer=webgl2"
"$pw" -s="$session" run-code --filename "$repo/script/browser_portable_conformance_checks.mjs" >"$tmp/checks.log" 2>&1 || { cat "$tmp/checks.log"; exit 1; }
cat "$tmp/checks.log"
grep -F -x -q '"peas-portable-conformance-passed"' "$tmp/checks.log"
"$pw" -s="$session" eval '() => ({user_agent: navigator.userAgent, renderer: window.unpolishedPeas.renderer, diagnostic: window.unpolishedPeas.rendererDiagnostic})' >"$tmp/environment.log" 2>&1
