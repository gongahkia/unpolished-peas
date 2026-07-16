#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT HUP INT TERM
session=unpolished-peas-browser-harness
pw=/Users/gongahkia/.codex/skills/playwright/scripts/playwright_cli.sh

cd "$repo"
script/package_web.sh "$tmp/package" --game bounce
bundle="$tmp/package/unpolished-peas-bounce-web"
python3 -m http.server 8123 --bind 127.0.0.1 --directory "$bundle" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open http://127.0.0.1:8123/
"$pw" -s="$session" snapshot >"$tmp/snapshot.txt"
"$pw" -s="$session" eval '() => Boolean(document.querySelector("canvas[data-unpolished-peas]"))' | grep -F true
"$pw" -s="$session" click 'canvas[data-unpolished-peas]'
"$pw" -s="$session" keydown w
"$pw" -s="$session" eval '() => Boolean(window.unpolishedPeas && window.unpolishedPeas.runtime && window.unpolishedPeas.host.input().down[0])' | grep -F true
"$pw" -s="$session" keyup w
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.storage().phase' | grep -F ready
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.captureFrame().startsWith("data:image/png")' | grep -F true
"$pw" -s="$session" eval '() => { const b = new TextEncoder().encode("browser harness"); window.unpolishedPeas.host.memory ? null : null; const memory = window.unpolishedPeas.host.memory; new Uint8Array(memory.buffer, 0, b.length).set(b); window.unpolishedPeas.runtime.up_browser_diagnostic_emit(0, b.length); return window.unpolishedPeas.host.artifacts().some((artifact) => artifact.name === "diagnostics.json" && artifact.data.includes("browser harness")); }' | grep -F true
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.lifecycle().scheduledFrames > 0' | grep -F true
"$pw" -s="$session" close
