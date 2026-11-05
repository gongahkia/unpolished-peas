#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
session=peas-input-workbench-$$
pw=$repo/script/playwright_cli.sh
cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        mkdir -p "$repo/zig-out/diagnostics/input-workbench"
        cp "$tmp"/*.log "$tmp"/*.png "$repo/zig-out/diagnostics/input-workbench/" 2>/dev/null || true
    fi
    "$pw" -s="$session" close >/dev/null 2>&1 || true
    if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
cd "$repo"
zig build web-input-workbench -Dwith_sdl=false
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$repo/zig-out/input-workbench" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open "http://127.0.0.1:$port/?renderer=webgl2"
"$pw" -s="$session" run-code --filename "$repo/script/browser_input_workbench_checks.mjs" >"$tmp/checks.log" 2>&1 || { cat "$tmp/checks.log"; exit 1; }
cat "$tmp/checks.log"
grep -F -x -q '"peas-input-workbench-passed"' "$tmp/checks.log"
