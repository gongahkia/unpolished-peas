#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
session=unpolished-peas-shell-$$
pw=$repo/script/playwright_cli.sh
diagnostics=${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/browser-shell}
case "$diagnostics" in /*) ;; *) diagnostics="$repo/$diagnostics" ;; esac
cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        mkdir -p "$diagnostics"
        cp "$tmp"/*.log "$diagnostics/" 2>/dev/null || true
        if [ -d "$tmp/.playwright-cli" ]; then cp -R "$tmp/.playwright-cli" "$diagnostics/"; fi
    fi
    "$pw" -s="$session" close >/dev/null 2>&1 || true
    if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
cd "$repo"
script/package_web.sh "$tmp/package" --game starter
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp/package/unpolished-peas-starter-web" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open "http://127.0.0.1:$port/?renderer=webgl2"
run_checks() {
    log="$tmp/$1.log"
    "$pw" -s="$session" run-code --filename "$repo/script/$2" >"$log" 2>&1 || { cat "$log"; return 1; }
    cat "$log"
    grep -F -x -q "\"$3\"" "$log"
}
run_checks checks browser_shell_checks.mjs peas-shell-checks-passed
run_checks materials browser_material_checks.mjs peas-material-checks-passed
