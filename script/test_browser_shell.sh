#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
session=unpolished-peas-shell-$$
pw=$repo/script/playwright_cli.sh
cleanup() {
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
"$pw" -s="$session" run-code --filename "$repo/script/browser_shell_checks.mjs" >"$tmp/checks.log"
cat "$tmp/checks.log"
grep -F -x -q '"peas-shell-checks-passed"' "$tmp/checks.log"
