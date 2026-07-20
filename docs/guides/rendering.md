# Stable 2D render contract

The v0.1 renderer is ordered logical-pixel 2D only: clear, filled rectangles, sprites, built-in text, camera-owned transforms, clip state, and alpha/additive blending. It excludes shaders, effects, depth, and every 3D capability.

Commands execute in submission order. `clear` replaces the logical canvas. Rectangle bounds are half-open (`x...x+w`, `y...y+h`); non-positive rectangle dimensions are no-ops. Sprite and text draws use the same ordering and active clip/blend state as rectangles.

`push_clip` intersects with the active logical-pixel clip; `pop_clip` restores the previous value. `push_blend(.alpha)` uses source-over alpha, while `.additive` adds alpha-scaled source channels with saturation. A pop without a matching push, or present with unbalanced clip/blend state, is rejected (`UnbalancedRenderState` natively and rejected browser ABI status).

`Camera2D` transforms world coordinates before rasterization. With camera position `(cx, cy)`, zoom `z`, rotation `r`, and viewport `(vx, vy, vw, vh)`, a point `(x, y)` maps to the viewport centre plus `z * rotate((x-cx, y-cy), -r)`. Browser camera setup does not implicitly clip, so browser callers push the logical-pixel viewport clip when needed. `CameraCanvas` and desktop command expansion apply the transform and establish that viewport clip for their own draws; the browser renderer applies the same transform before its WebGL 2 or WebGPU submission.

The backend-neutral fixture is [`stable-core-v1.json`](../../src/fixtures/renderer/stable-core-v1.json). It covers opaque and alpha sprites, built-in text, opaque rectangles, source-over and additive blend, nested clips, and a scaled camera transform. Native SDL GPU/OpenGL conformance expands that fixture to deterministic reference pixels. Forced browser WebGL 2/WebGPU runs consume the exact JSON and compare captures with a deterministic CPU reference. The permitted absolute RGBA per-channel delta is one.

Run `zig build test-renderer-conformance`, `zig build test-renderer-cross-backend`, `zig build test-browser-renderer-parity`, and `zig build test-renderer-three-backend`. The three-backend check compares the logical 64×32 capture before presentation chrome, using the same absolute per-channel tolerance of one; a mismatch retains the fixture, desktop raw pixels and OS/architecture/SDL-runtime/driver/shader metadata, browser PNGs, browser command traces, diagnostics, and browser user-agent/platform metadata under `zig-out/diagnostics/renderer-three-backend/`.
