#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
session=peas-font-layout-$$
pw=$repo/script/playwright_cli.sh
diagnostics=$repo/zig-out/diagnostics/font-layout
cleanup() {
    result=$?
    mkdir -p "$diagnostics"
    cp "$tmp"/*.log "$tmp"/*.png "$diagnostics/" 2>/dev/null || true
    "$pw" -s="$session" close >/dev/null 2>&1 || true
    if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$tmp"
    exit "$result"
}
trap cleanup EXIT HUP INT TERM
cd "$repo"
zig build web-font-layout -Dwith_sdl=false
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$repo/zig-out/font-layout" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open "http://127.0.0.1:$port/?renderer=webgl2" >"$tmp/open.log" 2>&1
"$pw" -s="$session" run-code --filename "$repo/script/browser_font_layout_checks.mjs" >"$tmp/checks.log" 2>&1 || { cat "$tmp/checks.log"; exit 1; }
cat "$tmp/checks.log"
python3 - "$tmp/checks.log" "$diagnostics/browser.json" <<'PY'
import json
import sys
from pathlib import Path
log = Path(sys.argv[1]).read_text()
report = json.loads(log.split("### Result\n", 1)[1].split("\n### ", 1)[0])
assert report["status"] == "peas-font-layout-passed"
output = Path(sys.argv[2])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, indent=2) + "\n")
PY
