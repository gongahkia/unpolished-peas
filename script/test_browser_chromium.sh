#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
game=${1:-bounce}
case "$game" in bounce|topdown) ;; *) printf '%s\n' 'usage: test_browser_chromium.sh [bounce|topdown]' >&2; exit 64 ;; esac
tmp=$(mktemp -d)
trap 'if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT HUP INT TERM
session=unpolished-peas-browser-harness
pw=/Users/gongahkia/.codex/skills/playwright/scripts/playwright_cli.sh

cd "$repo"
script/package_web.sh "$tmp/package" --game "$game"
bundle="$tmp/package/unpolished-peas-$game-web"
python3 -m http.server 8123 --bind 127.0.0.1 --directory "$bundle" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open http://127.0.0.1:8123/?renderer=webgl2
"$pw" -s="$session" snapshot >"$tmp/snapshot.txt"
"$pw" -s="$session" eval '() => Boolean(document.querySelector("canvas[data-unpolished-peas]"))' | grep -F true
"$pw" -s="$session" eval "() => document.querySelector('canvas[data-unpolished-peas]').dataset.game === '$game'" | grep -F true
"$pw" -s="$session" click 'canvas[data-unpolished-peas]'
"$pw" -s="$session" keydown w
"$pw" -s="$session" eval '() => Boolean(window.unpolishedPeas && window.unpolishedPeas.runtime && window.unpolishedPeas.host.input().down[0])' | grep -F true
"$pw" -s="$session" keyup w
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.storage().phase' | grep -F ready
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.captureFrame().startsWith("data:image/png")' | grep -F true
"$pw" -s="$session" eval '() => { const b = new TextEncoder().encode("browser harness"); window.unpolishedPeas.host.memory ? null : null; const memory = window.unpolishedPeas.host.memory; new Uint8Array(memory.buffer, 0, b.length).set(b); window.unpolishedPeas.runtime.up_browser_diagnostic_emit(0, b.length); return window.unpolishedPeas.host.artifacts().some((artifact) => artifact.name === "diagnostics.json" && artifact.data.includes("browser harness")); }' | grep -F true
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.lifecycle().scheduledFrames > 0' | grep -F true
"$pw" -s="$session" eval '() => window.unpolishedPeas.renderer' | grep -F webgl2
"$pw" -s="$session" eval '() => { const diagnostic = window.unpolishedPeas.rendererDiagnostic; const artifact = window.unpolishedPeas.host.artifacts().find((value) => value.name === "renderer-diagnostics.json"); return diagnostic.version === 1 && diagnostic.requested_renderer === "webgl2" && diagnostic.selected_renderer === "webgl2" && diagnostic.fallback_reason === null && diagnostic.context_status === "ready" && diagnostic.adapter_status === "not_applicable" && diagnostic.device_status === "not_applicable" && Boolean(artifact) && artifact.data === JSON.stringify(diagnostic); }' | grep -F true
"$pw" -s="$session" eval 'async () => { const {createWebGpuBackend, WebGpuBackendError} = await import("./webgpu_backend.mjs"); const canvas = document.createElement("canvas"); try { const backend = await createWebGpuBackend({canvas}); if (!backend.resize(64, 32) || !backend.clear(0xff000000) || !backend.present()) throw new Error("webgpu lifecycle failed"); const diagnostic = backend.diagnostic(); backend.destroy(); return diagnostic.adapter_status === "ready" && diagnostic.device_status === "ready" ? "webgpu-ready" : "webgpu-invalid"; } catch (error) { if (error instanceof WebGpuBackendError && ["webgpu_unavailable", "adapter_request_failed", "adapter_unavailable", "device_request_failed", "device_unavailable", "canvas_context_unavailable", "canvas_format_unavailable"].includes(error.code)) return "webgpu-unavailable"; throw error; } }' | grep -E 'webgpu-(ready|unavailable)'
"$pw" -s="$session" close
"$pw" -s="$session" open http://127.0.0.1:8123/?renderer=webgpu
"$pw" -s="$session" eval '() => { const diagnostic = window.unpolishedPeas?.rendererDiagnostic; const artifact = window.unpolishedPeas?.host?.artifacts().find((value) => value.name === "renderer-diagnostics.json"); return diagnostic?.version === 1 && diagnostic.requested_renderer === "webgpu" && ((diagnostic.selected_renderer === "webgpu" && diagnostic.capabilities.webgpu === "available" && diagnostic.adapter_status === "ready" && diagnostic.device_status === "ready") || (diagnostic.selected_renderer === null && diagnostic.capabilities.webgpu === "unavailable" && diagnostic.fallback_reason)) && Boolean(artifact) && artifact.data === JSON.stringify(diagnostic); }' | grep -F true
"$pw" -s="$session" close
"$pw" -s="$session" open http://127.0.0.1:8123/?renderer=auto
"$pw" -s="$session" eval '() => { const diagnostic = window.unpolishedPeas?.rendererDiagnostic; return diagnostic?.version === 1 && diagnostic.requested_renderer === "auto" && ((diagnostic.selected_renderer === "webgpu" && diagnostic.fallback_reason === null) || (diagnostic.selected_renderer === "webgl2" && diagnostic.capabilities.webgpu === "unavailable" && diagnostic.fallback_reason?.endsWith("_fallback"))); }' | grep -F true
"$pw" -s="$session" close
printf '%s\n' "browser-chromium passed: game=$game"
