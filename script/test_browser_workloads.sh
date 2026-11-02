#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT HUP INT TERM
session=unpolished-peas-workload-catalog
pw=$repo/script/playwright_cli.sh

cd "$repo"
script/package_web.sh "$tmp/package" --game bounce
bundle="$tmp/package/unpolished-peas-bounce-web"
python3 -m http.server 8125 --bind 127.0.0.1 --directory "$bundle" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open http://127.0.0.1:8125/?renderer=webgl2
"$pw" -s="$session" snapshot >"$tmp/snapshot.txt"
"$pw" -s="$session" eval 'async () => { const catalog = await fetch("./workloads-v1.json").then((response) => response.json()); const {runWorkloadCatalog} = await import("./workload_runner.mjs"); return JSON.stringify(await runWorkloadCatalog(window.unpolishedPeas.runtime, window.unpolishedPeas.host, catalog)); }' 2>&1 | tee "$tmp/workload-result.txt" | grep -F '\"version\":1,\"workloads\":6,\"frames\":120'
"$pw" -s="$session" close
printf '%s\n' 'browser-workloads passed: renderer=webgl2 workloads=6'
