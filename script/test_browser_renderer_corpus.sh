#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'if [ "${server:-}" ]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT HUP INT TERM
session=unpolished-peas-renderer-corpus
pw=/Users/gongahkia/.codex/skills/playwright/scripts/playwright_cli.sh

cd "$repo"
script/package_web.sh "$tmp/package" --game bounce
bundle="$tmp/package/unpolished-peas-bounce-web"
python3 -m http.server 8124 --bind 127.0.0.1 --directory "$bundle" >"$tmp/server.log" 2>&1 &
server=$!
sleep 1
cd "$tmp"
"$pw" -s="$session" open http://127.0.0.1:8124/
"$pw" -s="$session" snapshot >"$tmp/snapshot.txt"
"$pw" -s="$session" eval '() => { const runtime = window.unpolishedPeas.runtime; const host = window.unpolishedPeas.host; const gl = host.context(); const status = 0; const pack = (r, g, b, a = 255) => (r | (g << 8) | (b << 16) | (a << 24)) >>> 0; const pixel = (x, y) => { const value = new Uint8Array(4); gl.readPixels(x, gl.canvas.height - y - 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, value); return [...value]; }; const expectPixel = (x, y, expected) => { const actual = pixel(x, y); if (actual.some((channel, index) => Math.abs(channel - expected[index]) > 1)) throw new Error(`renderer corpus mismatch at ${x},${y}: ${actual} != ${expected}`); }; const begin = () => { if (runtime.up_browser_gl_context_create(8, 6) !== status) throw new Error("WebGL2 context unavailable"); if (runtime.up_browser_clear(pack(19, 37, 61)) !== status) throw new Error("clear failed"); }; begin(); runtime.up_browser_draw_rect(0, 0, 1, 1, pack(1, 2, 3)); runtime.up_browser_draw_rect(1, 0, 1, 1, pack(5, 6, 7)); runtime.up_browser_draw_rect(7, 5, 1, 1, pack(9, 10, 11)); runtime.up_browser_present(0); expectPixel(0, 0, [1, 2, 3, 255]); expectPixel(1, 0, [5, 6, 7, 255]); expectPixel(2, 1, [19, 37, 61, 255]); expectPixel(7, 5, [9, 10, 11, 255]); begin(); runtime.up_browser_push_clip(2, 4, 1, 1); runtime.up_browser_draw_rect(0, 0, 8, 6, pack(13, 17, 23)); runtime.up_browser_pop_clip(); runtime.up_browser_draw_rect(7, 5, 1, 1, pack(9, 10, 11)); runtime.up_browser_present(0); expectPixel(2, 0, [19, 37, 61, 255]); expectPixel(2, 4, [13, 17, 23, 255]); expectPixel(7, 5, [9, 10, 11, 255]); begin(); runtime.up_browser_push_clip(2, 1, 1, 1); runtime.up_browser_draw_rect(0, 0, 8, 6, pack(255, 0, 0, 128)); runtime.up_browser_push_blend(1); runtime.up_browser_draw_rect(0, 0, 8, 6, pack(0, 0, 255, 128)); runtime.up_browser_pop_blend(); runtime.up_browser_pop_clip(); runtime.up_browser_draw_rect(7, 5, 1, 1, pack(9, 10, 11)); runtime.up_browser_present(0); expectPixel(1, 1, [19, 37, 61, 255]); expectPixel(2, 1, [137, 18, 158, 255]); expectPixel(7, 5, [9, 10, 11, 255]); return "webgl2 renderer corpus passed"; }' | grep -F 'webgl2 renderer corpus passed'
"$pw" -s="$session" close
