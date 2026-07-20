#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
diagnostics=${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/browser-safari}
port=${UP_SAFARI_WEBDRIVER_PORT:-4444}
driver_url=${UP_SAFARI_WEBDRIVER_URL:-http://127.0.0.1:$port}
tmp=$(mktemp -d)
cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        mkdir -p "$diagnostics"
        cp "$tmp"/*.log "$diagnostics" 2>/dev/null || true
        cp -R "$tmp/artifacts" "$diagnostics" 2>/dev/null || true
    fi
    if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi
    if [ "${driver:-}" ]; then kill "$driver" 2>/dev/null || true; fi
    rm -rf "$tmp"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

command -v safaridriver >/dev/null || { printf '%s\n' 'Safari WebDriver unavailable: install macOS Safari.' >&2; exit 69; }
if ! curl -fsS "$driver_url/status" >/dev/null 2>&1; then
    safaridriver -p "$port" --diagnose >"$tmp/safaridriver.log" 2>&1 &
    driver=$!
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if curl -fsS "$driver_url/status" >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    test "$ready" -eq 1 || { printf 'Safari WebDriver did not start: %s\n' "$tmp/safaridriver.log" >&2; exit 69; }
fi

script/package_web.sh "$tmp/package" --game bounce
bundle="$tmp/package/unpolished-peas-bounce-web"
python3 -m http.server 8125 --bind 127.0.0.1 --directory "$bundle" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
UP_SAFARI_WEBDRIVER_URL="$driver_url" node "$repo/script/safari_webdriver.mjs" "http://127.0.0.1:8125" "$tmp/artifacts"
mkdir -p "$diagnostics"
cp -R "$tmp/artifacts" "$diagnostics"
cp "$tmp/safaridriver.log" "$diagnostics" 2>/dev/null || true
printf '%s\n' "Safari browser smoke passed: artifacts=$diagnostics/artifacts"
