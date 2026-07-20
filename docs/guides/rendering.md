# Stable 2D render contract

The v0.1 renderer is ordered logical-pixel 2D only: clear, filled rectangles, sprites, built-in text, camera-owned transforms, clip state, and alpha/additive blending. It excludes shaders, effects, depth, and every 3D capability.

Commands execute in submission order. `clear` replaces the logical canvas. Rectangle bounds are half-open (`x...x+w`, `y...y+h`); non-positive rectangle dimensions are no-ops. Sprite and text draws use the same ordering and active clip/blend state as rectangles.

## Built-in text subset

[`debug-5x7-v1.json`](../../src/fixtures/text/debug-5x7-v1.json) is the bundled text fixture for native, WebGL 2, and WebGPU. It defines 5×7 glyphs with a six-pixel advance and eight-pixel line height. The subset is ASCII letters (case-folded), digits, space, `-`, `_`, `.`, `:`, and `/`; other code points render the bundled `?` fallback. Newline starts a new eight-pixel line. Browser hosts decode malformed UTF-8 with the same replacement progression as native before fallback selection.

The browser uploads this fixture once as a nearest-sampled internal glyph atlas. Glyphs preserve active clip/blend/camera state and batch through the normal sprite path on WebGL 2 and WebGPU. A missing or malformed packaged fixture prevents startup with `asset_load_failed:debug_font_v1`; no game-facing font API is added.

`push_clip` intersects with the active logical-pixel clip; `pop_clip` restores the previous value. `push_blend(.alpha)` uses source-over alpha, while `.additive` adds alpha-scaled source channels with saturation. A pop without a matching push, or present with unbalanced clip/blend state, is rejected (`UnbalancedRenderState` natively and rejected browser ABI status).

`Camera2D` transforms world coordinates before rasterization. With camera position `(cx, cy)`, zoom `z`, rotation `r`, and viewport `(vx, vy, vw, vh)`, a point `(x, y)` maps to the viewport centre plus `z * rotate((x-cx, y-cy), -r)`. Browser camera setup does not implicitly clip, so browser callers push the logical-pixel viewport clip when needed. `CameraCanvas` and desktop command expansion apply the transform and establish that viewport clip for their own draws; the browser renderer applies the same transform before its WebGL 2 or WebGPU submission.

The backend-neutral fixture is [`stable-core-v1.json`](../../src/fixtures/renderer/stable-core-v1.json). It covers opaque and alpha sprites, plain/multiline/clipped/fallback built-in text, opaque rectangles, source-over and additive blend, nested clips, and a scaled camera transform. Native SDL GPU/OpenGL conformance expands that fixture to deterministic reference pixels. Forced browser WebGL 2/WebGPU runs consume the exact JSON and compare captures with a deterministic CPU reference. The permitted absolute RGBA per-channel delta is one.

Run `zig build test-renderer-conformance`, `zig build test-renderer-cross-backend`, `zig build test-browser-renderer-parity`, and `zig build test-renderer-three-backend`. The three-backend check compares the logical 64×32 capture before presentation chrome, using the same absolute per-channel tolerance of one; a mismatch retains the fixture, desktop raw pixels and OS/architecture/SDL-runtime/driver/shader metadata, browser PNGs, browser command traces, diagnostics, and browser user-agent/platform metadata under `zig-out/diagnostics/renderer-three-backend/`.
