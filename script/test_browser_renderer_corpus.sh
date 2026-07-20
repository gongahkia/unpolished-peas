#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
diagnostics=${UP_DIAGNOSTICS_ROOT:-$repo/zig-out/diagnostics/browser-renderer-parity}
tmp=$(mktemp -d)
trap 'if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT HUP INT TERM
session=unpolished-peas-renderer-corpus-$$
pw=$repo/script/playwright_cli.sh

decode_result() {
    encoded=$(sed -n 's/^"\([A-Za-z0-9+\/=][A-Za-z0-9+\/=]*\)"$/\1/p' "$1" | head -n 1)
    test -n "$encoded"
    if printf '%s' "$encoded" | base64 -D > "$2" 2>/dev/null; then return; fi
    printf '%s' "$encoded" | base64 -d > "$2"
}

capture_renderer() {
    renderer=$1
    output=$tmp/$renderer.out
    "$pw" -s="$session" open "http://127.0.0.1:8124/?renderer=$renderer"
    "$pw" -s="$session" eval 'async () => { const requested = new URLSearchParams(location.search).get("renderer"); const deadline = performance.now() + 15000; while ((!window.unpolishedPeas?.runtime || window.unpolishedPeas?.renderer !== requested) && performance.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50)); if (!window.unpolishedPeas?.runtime || window.unpolishedPeas?.renderer !== requested) throw new Error(`browser runtime unavailable: ${requested}`); return true; }' > "$tmp/$renderer.ready.out"
    "$pw" -s="$session" snapshot > "$tmp/$renderer.snapshot.txt"
    "$pw" -s="$session" eval 'async () => { const renderer = new URLSearchParams(location.search).get("renderer"); const result = {renderer, ready: false, dimensions: null, image: null, pixels: null, diagnostic: window.unpolishedPeas?.rendererDiagnostic ?? null, commands: [], error: null}; const encode = (value) => { const bytes = new TextEncoder().encode(JSON.stringify(value)); let text = ""; for (const byte of bytes) text += String.fromCharCode(byte); return btoa(text); }; const pack = (r, g, b, a = 255) => (r | (g << 8) | (b << 16) | (a << 24)) >>> 0; const width = 16; const height = 16; try { const api = window.unpolishedPeas; const runtime = api?.runtime; const host = api?.host; if (!runtime || !host) throw new Error("browser runtime unavailable"); if (api.renderer !== renderer) throw new Error(`requested ${renderer}, selected ${api.renderer ?? "none"}`); const call = (name, ...args) => { const command = {name, args}; result.commands.push(command); host.recordCommand(command); const status = runtime[name](...args); if (status !== 0) throw new Error(`${name} returned ${status}`); }; call("up_browser_gl_context_create", width, height); call("up_browser_clear", pack(19, 37, 61)); call("up_browser_draw_rect", 0, 0, width, height, pack(255, 0, 0, 128)); call("up_browser_push_clip", 3, 2, 10, 12); call("up_browser_push_blend", 1); call("up_browser_draw_rect", 0, 0, width, height, pack(0, 0, 255, 128)); call("up_browser_pop_blend"); call("up_browser_pop_clip"); const pixels = [12, 34, 56, 255, 78, 90, 12, 255, 34, 56, 78, 255, 90, 12, 34, 255]; new Uint8Array(host.memory.buffer, 1024, pixels.length).set(pixels); const textureCommand = {name: "up_browser_gl_resource_create", args: [1, 0]}; result.commands.push(textureCommand); host.recordCommand(textureCommand); const texture = runtime.up_browser_gl_resource_create(1, 0); if (!texture) throw new Error("up_browser_gl_resource_create returned 0"); call("up_browser_texture_upload", texture, 2, 2, 1024, pixels.length, 0); call("up_browser_draw_sprite", texture, 0, 0, 2, 2, 9, 10, 4, 4, 0xffffffff, 0); const text = new TextEncoder().encode("A\\nB"); new Uint8Array(host.memory.buffer, 2048, text.length).set(text); call("up_browser_draw_text", 2048, text.length, 1, 1, 0xffffffff); call("up_browser_present", 0); const image = host.captureFrame(); if (!image) throw new Error("captureFrame returned no image"); const decoded = new Image(); decoded.src = image; await decoded.decode(); const capture = document.createElement("canvas"); capture.width = width; capture.height = height; const context = capture.getContext("2d", {willReadFrequently: true}); context.drawImage(decoded, 0, 0); result.ready = true; result.dimensions = {width: capture.width, height: capture.height}; result.image = image; result.pixels = Array.from(context.getImageData(0, 0, width, height).data); const destroy = {name: "up_browser_gl_resource_destroy", args: [1, texture]}; result.commands.push(destroy); host.recordCommand(destroy); runtime.up_browser_gl_resource_destroy(1, texture); } catch (error) { result.error = error instanceof Error ? error.message : String(error); } result.diagnostic = window.unpolishedPeas?.rendererDiagnostic ?? result.diagnostic; return encode(result); }' > "$output"
    "$pw" -s="$session" eval 'async () => { const result = {renderer: new URLSearchParams(location.search).get("renderer"), ready: false, dimensions: null, image: null, pixels: null, image_assets: null, diagnostic: window.unpolishedPeas?.rendererDiagnostic ?? null, commands: [], error: null}; const encode = (value) => { const bytes = new TextEncoder().encode(JSON.stringify(value)); let text = ""; for (const byte of bytes) text += String.fromCharCode(byte); return btoa(text); }; try { const api = window.unpolishedPeas; if (!api?.runtime || !api?.host) throw new Error("browser runtime unavailable"); const imageAssets = await import("./image_asset_runner.mjs"); result.image_assets = await imageAssets.verifyStableImageAssets(api.runtime, api.host, "./assets/ball.png"); const fixture = await fetch("./renderer-contract-v1.json").then((response) => { if (!response.ok) throw new Error("renderer contract fixture unavailable"); return response.json(); }); const contract = await import("./renderer_contract_runner.mjs"); const execution = contract.runRendererContract(api.runtime, api.host, fixture); result.commands = execution.commands; const image = api.host.captureFrame(); if (!image) throw new Error("captureFrame returned no image"); const decoded = new Image(); decoded.src = image; await decoded.decode(); const capture = document.createElement("canvas"); capture.width = execution.dimensions.width; capture.height = execution.dimensions.height; const context = capture.getContext("2d", {willReadFrequently: true}); context.drawImage(decoded, 0, 0); result.ready = true; result.dimensions = execution.dimensions; result.image = image; result.pixels = Array.from(context.getImageData(0, 0, capture.width, capture.height).data); } catch (error) { result.error = error instanceof Error ? error.message : String(error); } result.diagnostic = window.unpolishedPeas?.rendererDiagnostic ?? result.diagnostic; return encode(result); }' > "$output"
    decode_result "$output" "$tmp/$renderer.json"
    "$pw" -s="$session" eval 'async () => { const bytes = new TextEncoder().encode(JSON.stringify({user_agent: navigator.userAgent, platform: navigator.platform})); let text = ""; for (const byte of bytes) text += String.fromCharCode(byte); return btoa(text); }' > "$tmp/$renderer.host.out"
    decode_result "$tmp/$renderer.host.out" "$tmp/$renderer.host.json"
    "$pw" -s="$session" close
}

cd "$repo"
python3 script/capability_matrix.py --check-nightly-row chromium-webgpu
script/package_web.sh "$tmp/package" --game bounce
bundle="$tmp/package/unpolished-peas-bounce-web"
python3 -m http.server 8124 --bind 127.0.0.1 --directory "$bundle" > "$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
capture_renderer webgl2
capture_renderer webgpu
if [ -n "${UP_RENDERER_CAPTURE_DIR:-}" ]; then
    mkdir -p "$UP_RENDERER_CAPTURE_DIR"
    cp "$tmp/webgl2.json" "$UP_RENDERER_CAPTURE_DIR/webgl2.json"
    cp "$tmp/webgpu.json" "$UP_RENDERER_CAPTURE_DIR/webgpu.json"
    cp "$tmp/webgl2.host.json" "$UP_RENDERER_CAPTURE_DIR/webgl2-host.json"
    cp "$tmp/webgpu.host.json" "$UP_RENDERER_CAPTURE_DIR/webgpu-host.json"
fi
node "$repo/script/compare_browser_renderer_captures.mjs" "$tmp/webgl2.json" "$tmp/webgpu.json" "$diagnostics" "$bundle/renderer-contract-v1.json"
