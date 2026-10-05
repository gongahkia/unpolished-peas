# Stable 2D render contract

The v0.1 renderer is ordered logical-pixel 2D: clear, filled rectangles, sprites, built-in text, camera-owned transforms, clip state, alpha/additive blending, and the CPU-reference effects described in [Advanced 2D](advanced-2d.md). It excludes depth, meshes, public GPU handles, compute, and every 3D capability.

Commands execute in submission order. `clear` replaces the logical canvas. Rectangle bounds are half-open (`x...x+w`, `y...y+h`); non-positive rectangle dimensions are no-ops. Sprite and text draws use the same ordering and active clip/blend state as rectangles.

## Built-in text subset

[`debug-5x7-v1.json`](../../src/fixtures/text/debug-5x7-v1.json) is the bundled text fixture for native, WebGL 2, and WebGPU. It defines 5×7 glyphs with a six-pixel advance and eight-pixel line height. The subset is ASCII letters (case-folded), digits, space, `-`, `_`, `.`, `:`, and `/`; other code points render the bundled `?` fallback. Newline starts a new eight-pixel line. Browser hosts decode malformed UTF-8 with the same replacement progression as native before fallback selection.

The browser uploads this fixture once as a nearest-sampled internal glyph atlas. Glyphs preserve active clip/blend/camera state and batch through the normal sprite path on WebGL 2 and WebGPU. A missing or malformed packaged fixture prevents startup with `asset_load_failed:debug_font_v1`. The fixture remains useful for zero-asset HUDs. Games that need an authored face can use the portable `assets.Font.decodeTrueType(@embedFile(...))` workflow in the [authored-assets guide](image-assets.md).

`push_clip` intersects with the active logical-pixel clip; `pop_clip` restores the previous value. `push_blend(.alpha)` uses source-over alpha, while `.additive` adds alpha-scaled source channels with saturation. A pop without a matching push, or present with unbalanced clip/blend state, is rejected (`UnbalancedRenderState` natively and rejected browser ABI status).

`Camera2D` transforms world coordinates before rasterization. With camera position `(cx, cy)`, zoom `z`, rotation `r`, and viewport `(vx, vy, vw, vh)`, a point `(x, y)` maps to the viewport centre plus `z * rotate((x-cx, y-cy), -r)`. Browser camera setup does not implicitly clip, so browser callers push the logical-pixel viewport clip when needed. `CameraCanvas` and desktop command expansion apply the transform and establish that viewport clip for their own draws; the browser renderer applies the same transform before its WebGL 2 or WebGPU submission.

The backend-neutral fixture is [`stable-core-v1.json`](../../src/fixtures/renderer/stable-core-v1.json). It covers opaque and alpha sprites, plain/multiline/clipped/fallback built-in text, opaque rectangles, source-over and additive blend, nested clips, and a scaled camera transform. Native SDL GPU/OpenGL conformance expands that fixture to deterministic reference pixels. Forced browser WebGL 2/WebGPU runs consume the exact JSON and compare captures with a deterministic CPU reference. The permitted absolute RGBA per-channel delta is one.

Run `zig build test-renderer-conformance`, `zig build test-renderer-cross-backend`, `zig build test-browser-renderer-parity`, and `zig build test-renderer-three-backend`. The three-backend check compares the logical 64×32 capture before presentation chrome, using the same absolute per-channel tolerance of one; a mismatch retains the fixture, desktop raw pixels and OS/architecture/SDL-runtime/driver/shader metadata, browser PNGs, browser command traces, diagnostics, and browser user-agent/platform metadata under `zig-out/diagnostics/renderer-three-backend/`.

The generic browser runtime now creates the same `Canvas` passed to a callback game and uploads its RGBA result through the browser host. Canvas effects and particle reference draws therefore share desktop/browser semantics. Existing specialised proof-game Wasm runtimes continue to use their direct command ABI.

## Offscreen 2D composition

[`RenderSurface`](render-surfaces.md) is the narrow persistent offscreen
Canvas facility. It uses the same logical-pixel primitives, clip state, blend
state, and presentation-independent color semantics as a normal Canvas, then
composes onto another Canvas with nearest or linear sampling. It is a
CPU-backed, backend-neutral surface—not a public GPU render target—and is
available in headless tests as well as native and browser builds.

## Performance guidance

`Canvas` remains the default renderer for small, logical-pixel 2D games. Its
CPU raster result is deterministic, testable headlessly, and uploaded as one
RGBA frame by native and browser presenters. `Renderer2D` is a separate
GPU-oriented queue for staged materials, post passes, and particle batches;
it is not a transparent replacement for the Canvas contract.

The internal `zig build -Doptimize=ReleaseFast benchmark-rendering` utility
uses four warm-up iterations and at least 48 Mi logical pixels per workload.
On the locally tested Intel macOS 15.7.7 host, a representative run cleared a
320×180 Canvas in 3.1 µs, drew 5,000 visible 16×16 opaque Canvas sprites in
2.5 ms, and nearest-composed a 320×180 surface to 1280×720 in 1.9 ms. Those
figures are host-specific observations, not frame-rate guarantees. They show
that low-resolution CPU Canvas work is appropriate for the reference games;
they do not establish an Apple Silicon performance result.

Prefer a low-resolution `RenderSurface` with nearest/integer scaling for
pixel-art presentation. Full-HD linear CPU surface scaling is deliberately a
practical limit: the same local run took about 23 ms for 320×180 to 1280×720
linear composition. Use `Renderer2D` when its distinct GPU features are
needed, especially large contiguous particle batches, rather than moving
ordinary Canvas games to a GPU API prematurely.
