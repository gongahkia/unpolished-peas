#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
game=${1:-bounce}
case "$game" in bounce|topdown|puzzle) ;; *) printf '%s\n' 'usage: test_browser_chromium.sh [bounce|topdown|puzzle]' >&2; exit 64 ;; esac
browser=${UP_BROWSER:-chromium}
case "$browser" in
    chromium) engine=chrome ;;
    firefox) engine=firefox ;;
    *) printf 'unsupported browser engine: %s\n' "$browser" >&2; exit 64 ;;
esac
allow_webgpu_unavailable=${UP_ALLOW_WEBGPU_UNAVAILABLE:-0}
diagnostics=${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/browser-$browser}
tmp=$(mktemp -d)
cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        mkdir -p "$diagnostics"
        "$pw" -s="$session" console > "$tmp/browser-console.log" 2>&1 || true
        capture_artifacts failure || true
        cp "$tmp"/*.log "$tmp"/*-artifacts.json "$diagnostics" 2>/dev/null || true
        if [ -d "$tmp/.playwright-cli" ]; then cp -R "$tmp/.playwright-cli" "$diagnostics/playwright" 2>/dev/null || true; fi
    fi
    if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$tmp"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
session=unpolished-peas-browser-harness
pw=$repo/script/playwright_cli.sh

capture_artifacts() {
    renderer=$1
    output=$tmp/$renderer-artifacts.out
    "$pw" -s="$session" eval "async () => { const api = window.unpolishedPeas; await api?.captureFrame?.(); const version = navigator.userAgent.match(/(?:Firefox|Chrome)\\/([\\d.]+)/)?.[1] ?? null; const value = {browser: {name: \"$browser\", version, user_agent: navigator.userAgent}, renderer: api?.renderer ?? null, diagnostic: api?.rendererDiagnostic ?? null, artifacts: api?.host?.artifacts?.() ?? []}; const bytes = new TextEncoder().encode(JSON.stringify(value)); let text = \"\"; for (const byte of bytes) text += String.fromCharCode(byte); return btoa(text); }" > "$output"
    encoded=$(sed -n 's/^"\([A-Za-z0-9+\/=][A-Za-z0-9+\/=]*\)"$/\1/p' "$output" | head -n 1)
    test -n "$encoded"
    if printf '%s' "$encoded" | base64 -D > "$tmp/$renderer-artifacts.json" 2>/dev/null; then return; fi
    printf '%s' "$encoded" | base64 -d > "$tmp/$renderer-artifacts.json"
}

cd "$repo"
script/package_web.sh "$tmp/package" --game "$game"
bundle="$tmp/package/unpolished-peas-$game-web"
python3 -m http.server 8123 --bind 127.0.0.1 --directory "$bundle" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" --session "$session" open http://127.0.0.1:8123/?renderer=webgl2 --browser "$engine"
"$pw" -s="$session" snapshot >"$tmp/snapshot.txt"
"$pw" -s="$session" eval '() => Boolean(document.querySelector("canvas[data-unpolished-peas]"))' | grep -F true
"$pw" -s="$session" eval "() => document.querySelector('canvas[data-unpolished-peas]').dataset.game === '$game'" | grep -F true
"$pw" -s="$session" click 'canvas[data-unpolished-peas]'
"$pw" --session "$session" mousedown
"$pw" --session "$session" keydown w
"$pw" -s="$session" eval '() => { const input = window.unpolishedPeas?.host.input(); return Boolean(window.unpolishedPeas?.runtime && input?.down[0] && input.pointerDown[0] && Number.isFinite(input.pointer.canvasX) && Number.isFinite(input.pointer.canvasY)); }' | grep -F true
if [ "$game" = topdown ]; then
    "$pw" -s="$session" eval '() => { const runtime = window.unpolishedPeas.runtime; return runtime.up_browser_topdown_render_status() === 0 && runtime.up_browser_topdown_player_y() < 48; }' | grep -F true
elif [ "$game" = puzzle ]; then
    "$pw" -s="$session" eval 'async () => { for (let frame = 0; frame < 20; frame += 1) { const runtime = window.unpolishedPeas.runtime; if (runtime.up_browser_puzzle_render_status() === 0 && runtime.up_browser_puzzle_selected() < 4 && runtime.up_browser_puzzle_lit() > 0) return true; await new Promise((resolve) => setTimeout(resolve, 16)); } return false; }' | grep -F true
fi
"$pw" -s="$session" eval '() => { window.dispatchEvent(new Event("blur")); const input = window.unpolishedPeas.host.input(); return !input.down[0] && !input.pointerDown[0] && input.released[0] && input.pointerReleased[0]; }' | grep -F true
"$pw" --session "$session" mouseup
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.storage().phase' | grep -F ready
"$pw" -s="$session" eval '() => { const audio = window.unpolishedPeas.host.audio(); return window.unpolishedPeas.runtime.up_browser_audio_state() === audio.state && typeof audio.phase === "string"; }' | grep -F true
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.captureFrame().startsWith("data:image/png")' | grep -F true
capture_artifacts webgl2
"$pw" -s="$session" eval '() => { const b = new TextEncoder().encode("browser harness"); window.unpolishedPeas.host.memory ? null : null; const memory = window.unpolishedPeas.host.memory; new Uint8Array(memory.buffer, 0, b.length).set(b); window.unpolishedPeas.runtime.up_browser_diagnostic_emit(0, b.length); return window.unpolishedPeas.host.artifacts().some((artifact) => artifact.name === "diagnostics.json" && artifact.data.includes("browser harness")); }' | grep -F true
"$pw" -s="$session" eval '() => window.unpolishedPeas.host.lifecycle().scheduledFrames > 0' | grep -F true
"$pw" -s="$session" eval '() => window.unpolishedPeas.renderer' | grep -F webgl2
"$pw" -s="$session" eval '() => { const diagnostic = window.unpolishedPeas.rendererDiagnostic; const artifact = window.unpolishedPeas.host.artifacts().find((value) => value.name === "renderer-diagnostics.json"); return diagnostic.version === 1 && diagnostic.requested_renderer === "webgl2" && diagnostic.selected_renderer === "webgl2" && diagnostic.fallback_reason === null && diagnostic.context_status === "ready" && diagnostic.adapter_status === "not_applicable" && diagnostic.device_status === "not_applicable" && Boolean(artifact) && artifact.data === JSON.stringify(diagnostic); }' | grep -F true
"$pw" -s="$session" eval 'async () => { const {createWebGpuBackend, WebGpuBackendError} = await import("./webgpu_backend.mjs"); const canvas = document.createElement("canvas"); try { const backend = await createWebGpuBackend({canvas}); if (!backend.resize(64, 32) || !backend.clear(0xff000000) || !backend.present()) throw new Error("webgpu lifecycle failed"); const diagnostic = backend.diagnostic(); backend.destroy(); return diagnostic.adapter_status === "ready" && diagnostic.device_status === "ready" ? "webgpu-ready" : "webgpu-invalid"; } catch (error) { if (error instanceof WebGpuBackendError && ["webgpu_unavailable", "adapter_request_failed", "adapter_unavailable", "device_request_failed", "device_unavailable", "canvas_context_unavailable", "canvas_format_unavailable"].includes(error.code)) return "webgpu-unavailable"; throw error; } }' | grep -E 'webgpu-(ready|unavailable)'
"$pw" -s="$session" close
"$pw" --session "$session" open http://127.0.0.1:8123/?renderer=webgpu --browser "$engine"
"$pw" -s="$session" snapshot >"$tmp/webgpu-snapshot.txt"
"$pw" -s="$session" eval "() => Boolean(document.querySelector('canvas[data-unpolished-peas]')) && document.querySelector('canvas[data-unpolished-peas]').dataset.game === '$game'" | grep -F true
"$pw" -s="$session" eval '() => { const diagnostic = window.unpolishedPeas?.rendererDiagnostic; const runtime = window.unpolishedPeas?.runtime; const artifact = window.unpolishedPeas?.host?.artifacts().find((value) => value.name === "renderer-diagnostics.json"); const rendered = diagnostic?.selected_renderer !== "webgpu" || (runtime.up_browser_gl_context_create(8, 6) === 0 && runtime.up_browser_clear(0xff000000) === 0 && runtime.up_browser_draw_rect(1, 1, 4, 3, 0x80ff0000) === 0 && runtime.up_browser_push_clip(2, 1, 2, 4) === 0 && runtime.up_browser_draw_rect(0, 0, 8, 6, 0x800000ff) === 0 && runtime.up_browser_pop_clip() === 0 && runtime.up_browser_present(0) === 0); return diagnostic?.version === 1 && diagnostic.requested_renderer === "webgpu" && ((diagnostic.selected_renderer === "webgpu" && diagnostic.capabilities.webgpu === "available" && diagnostic.adapter_status === "ready" && diagnostic.device_status === "ready" && rendered) || (diagnostic.selected_renderer === null && diagnostic.capabilities.webgpu === "unavailable" && diagnostic.fallback_reason)) && Boolean(artifact) && artifact.data === JSON.stringify(diagnostic); }' | grep -F true
webgpu_state=$("$pw" --session "$session" eval '() => { const diagnostic = window.unpolishedPeas?.rendererDiagnostic; return diagnostic?.selected_renderer === "webgpu" ? "webgpu-ready" : `webgpu-unavailable:${diagnostic?.fallback_reason ?? "unknown"}`; }' | sed -n 's/^"\(webgpu-[^"]*\)"$/\1/p' | tail -n 1)
test -n "$webgpu_state"
case "$webgpu_state" in
    *webgpu-ready*) webgpu_ready=1 ;;
    *webgpu-unavailable:*)
        if [ "$allow_webgpu_unavailable" != 1 ]; then
            printf 'forced WebGPU unavailable: browser=%s diagnostic=%s\n' "$browser" "$webgpu_state" >&2
            exit 69
        fi
        printf 'forced WebGPU unavailable as declared: browser=%s diagnostic=%s\n' "$browser" "$webgpu_state"
        webgpu_ready=0
        ;;
    *) printf 'forced WebGPU setup returned an invalid state: browser=%s diagnostic=%s\n' "$browser" "$webgpu_state" >&2; exit 1 ;;
esac
if [ "$webgpu_ready" -eq 1 ]; then
capture_artifacts webgpu
if [ "$game" = topdown ]; then
    "$pw" -s="$session" eval '() => { const runtime = window.unpolishedPeas.runtime; return runtime.up_browser_topdown_render_status() === 0 && Number.isFinite(runtime.up_browser_topdown_player_x()) && Number.isFinite(runtime.up_browser_topdown_player_y()); }' | grep -F true
elif [ "$game" = puzzle ]; then
    "$pw" -s="$session" eval '() => { const runtime = window.unpolishedPeas.runtime; return runtime.up_browser_puzzle_selected() === 4 && runtime.up_browser_puzzle_lit() === 5; }' | grep -F true
fi
"$pw" -s="$session" click 'canvas[data-unpolished-peas]'
"$pw" --session "$session" mousedown
"$pw" --session "$session" keydown w
"$pw" -s="$session" eval '() => { const input = window.unpolishedPeas?.host.input(); return Boolean(window.unpolishedPeas?.runtime && input?.down[0] && input.pointerDown[0] && Number.isFinite(input.pointer.canvasX) && Number.isFinite(input.pointer.canvasY)); }' | grep -F true
if [ "$game" = puzzle ]; then
    "$pw" -s="$session" eval 'async () => { for (let frame = 0; frame < 20; frame += 1) { if (window.unpolishedPeas.runtime.up_browser_puzzle_selected() < 4) return true; await new Promise((resolve) => setTimeout(resolve, 16)); } return false; }' | grep -F true
fi
"$pw" -s="$session" eval '() => { window.dispatchEvent(new Event("blur")); const input = window.unpolishedPeas.host.input(); return !input.down[0] && !input.pointerDown[0] && input.released[0] && input.pointerReleased[0]; }' | grep -F true
"$pw" --session "$session" mouseup
"$pw" -s="$session" eval '() => { const audio = window.unpolishedPeas.host.audio(); return window.unpolishedPeas.runtime.up_browser_audio_state() === audio.state && typeof audio.phase === "string" && window.unpolishedPeas.host.captureFrame().startsWith("data:image/png"); }' | grep -F true
"$pw" -s="$session" eval 'async () => { if (window.unpolishedPeas?.renderer !== "webgpu") return true; const runtime = window.unpolishedPeas.runtime; const pack = (r, g, b, a = 255) => (r | (g << 8) | (b << 16) | (a << 24)) >>> 0; const results = [runtime.up_browser_gl_context_create(8, 6), runtime.up_browser_clear(pack(19, 37, 61)), runtime.up_browser_draw_rect(1, 1, 4, 3, pack(255, 0, 0, 128)), runtime.up_browser_push_clip(2, 1, 2, 4), runtime.up_browser_draw_rect(0, 0, 8, 6, pack(0, 0, 255, 128)), runtime.up_browser_pop_clip(), runtime.up_browser_present(0)]; if (results.some((status) => status !== 0)) return false; const image = new Image(); image.src = window.unpolishedPeas.host.captureFrame(); await image.decode(); const output = document.createElement("canvas"); output.width = 8; output.height = 6; const context = output.getContext("2d"); context.drawImage(image, 0, 0); const pixel = (x, y) => [...context.getImageData(x, y, 1, 1).data]; return JSON.stringify({outside: pixel(0, 0), red: pixel(1, 1), blend: pixel(2, 1)}) === JSON.stringify({outside: [19, 37, 61, 255], red: [137, 18, 30, 255], blend: [68, 9, 143, 255]}); }' | grep -F true
"$pw" -s="$session" eval 'async () => { if (window.unpolishedPeas?.renderer !== "webgpu") return true; const runtime = window.unpolishedPeas.runtime; const memory = window.unpolishedPeas.host.memory; const pixels = [12, 34, 56, 255, 78, 90, 12, 255, 34, 56, 78, 255, 90, 12, 34, 255]; new Uint8Array(memory.buffer, 1024, pixels.length).set(pixels); const texture = runtime.up_browser_gl_resource_create(1, 0); const statuses = [runtime.up_browser_gl_context_create(8, 6), runtime.up_browser_clear(0xff000000), runtime.up_browser_texture_upload(texture, 2, 2, 1024, pixels.length, 0), runtime.up_browser_draw_sprite(texture, 0, 0, 2, 2, 3, 2, 2, 2, 0xffffffff, 0), runtime.up_browser_present(0)]; if (statuses.some((status) => status !== 0)) return false; const image = new Image(); image.src = window.unpolishedPeas.host.captureFrame(); await image.decode(); const output = document.createElement("canvas"); output.width = 8; output.height = 6; const context = output.getContext("2d"); context.drawImage(image, 0, 0); const pixel = [...context.getImageData(3, 2, 1, 1).data]; runtime.up_browser_gl_resource_destroy(1, texture); return JSON.stringify(pixel) === JSON.stringify([12, 34, 56, 255]); }' | grep -F true
"$pw" -s="$session" eval 'async () => { if (window.unpolishedPeas?.renderer !== "webgpu") return true; const runtime = window.unpolishedPeas.runtime; const memory = window.unpolishedPeas.host.memory; const bytes = new TextEncoder().encode("A\nB"); new Uint8Array(memory.buffer, 2048, bytes.length).set(bytes); const draw = () => runtime.up_browser_draw_text(2048, bytes.length, 1, 1, 0xffffffff); if ([runtime.up_browser_gl_context_create(16, 16), runtime.up_browser_clear(0xff000000), draw(), runtime.up_browser_present(0)].some((status) => status !== 0)) return false; const sample = async () => { const image = new Image(); image.src = window.unpolishedPeas.host.captureFrame(); await image.decode(); const output = document.createElement("canvas"); output.width = 16; output.height = 16; const context = output.getContext("2d"); context.drawImage(image, 0, 0); return (x, y) => [...context.getImageData(x, y, 1, 1).data]; }; let pixel = await sample(); if (JSON.stringify(pixel(2, 1)) !== JSON.stringify([255, 255, 255, 255]) || JSON.stringify(pixel(2, 9)) !== JSON.stringify([255, 255, 255, 255])) return false; if ([runtime.up_browser_clear(0xff000000), runtime.up_browser_push_clip(3, 1, 1, 7), draw(), runtime.up_browser_pop_clip(), runtime.up_browser_present(0)].some((status) => status !== 0)) return false; pixel = await sample(); return JSON.stringify(pixel(2, 1)) === JSON.stringify([0, 0, 0, 255]) && JSON.stringify(pixel(3, 1)) === JSON.stringify([255, 255, 255, 255]); }' | grep -F true
else
capture_artifacts webgpu || printf '%s\n' "forced WebGPU unavailable artifact capture failed: browser=$browser" >&2
fi
"$pw" -s="$session" close || test "$webgpu_ready" -eq 0
"$pw" --session "$session" open http://127.0.0.1:8123/?renderer=auto --browser "$engine"
"$pw" -s="$session" eval '() => { const diagnostic = window.unpolishedPeas?.rendererDiagnostic; return diagnostic?.version === 1 && diagnostic.requested_renderer === "auto" && ((diagnostic.selected_renderer === "webgpu" && diagnostic.fallback_reason === null) || (diagnostic.selected_renderer === "webgl2" && diagnostic.capabilities.webgpu === "unavailable" && diagnostic.fallback_reason?.endsWith("_fallback"))); }' | grep -F true
"$pw" -s="$session" close
printf '%s\n' "browser smoke passed: browser=$browser game=$game"
