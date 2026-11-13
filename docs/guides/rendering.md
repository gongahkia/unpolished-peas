# Rendering: Canvas first

Call reference: [Canvas and RenderSurface](../api/drawing.md), including
[drawSurface](../api/drawing.md#graphics-Canvas-drawSurface), saved clip/blend
state and ownership.

For an ordinary `GameProtocol` game, start with `ctx.requireCanvas()`.
Sprites, primitives and authored text rasterize into logical CPU pixels;
the native/browser host uploads that result for presentation. A GPU presenter
does not make the game's Canvas drawing GPU-rasterized. A larger window can
display a small logical Canvas without making the game draw at window resolution.

## Choose a rendering path

| Need | Use | Execution and limits |
| --- | --- | --- |
| Sprites, shapes, camera and text | `Canvas`, `CameraCanvas`, `Font` | Default portable CPU drawing; logical pixels can be tested headlessly |
| Retain an offscreen image, panel or world | [RenderSurface](render-surfaces.md) and `Canvas.drawSurface` | Owned CPU pixels, immediate nearest/linear composition, exact CPU reference |
| Scale and alpha-compose several retained surfaces after CPU drawing becomes costly | [SurfaceCompositor](gpu-surface-composition.md) | Opt-in prototype on **SDL GPU / WebGL 2**; opaque final output, explicit ordering and borrowed lifetimes |
| Custom shader effects or GPU particles | [Renderer2D and advanced 2D](advanced-2d.md) | Separate staged queues; SDL GPU / WebGL 2 / WebGPU; shaders require target artifacts |

Keep Canvas for the first game. Use a small logical resolution and scale at
presentation when it fits the art; measure the actual game before moving work
to the opt-in compositor. It accelerates surface scaling/composition, not
sprite or text rasterization. Its CPU evaluator is the reference for tests;
the host Canvas alone does not contain the final GPU-composed frame.

Browser `?renderer=auto` prefers WebGPU when ready and falls back to WebGL 2.
It does **not** select a renderer based on queued game features. A game using
`SurfaceCompositor` must request `?renderer=webgl2` (for example,
`http://127.0.0.1:8000/?renderer=webgl2`). WebGPU and native OpenGL reject that
queue; there is no automatic CPU emulation. Ordinary Canvas games can keep
automatic selection. [Capability status](capabilities.md) and
[runtime evidence](platforms.md) remain separate from this API choice.

For authored proportional text, use [Font measurement and prepared layouts](authored-text-layout.md).
The debug-font `graphics.layoutText` helper uses different metrics and is not
an authored-font layout API.

## Stable logical drawing contract

The v1.0 renderer is ordered logical-pixel 2D: clear, filled rectangles, sprites, built-in text, camera-owned transforms, clip state, alpha/additive blending, and the CPU-reference effects described in [Advanced 2D](advanced-2d.md). It excludes depth, meshes, public GPU handles, compute, and every 3D capability.

Commands execute in submission order. `clear` replaces the logical canvas. Rectangle bounds are half-open (`x...x+w`, `y...y+h`); non-positive rectangle dimensions are no-ops. Sprite and text draws use the same ordering and active clip/blend state as rectangles.

## Built-in text subset

[`debug-5x7-v1.json`](../../src/fixtures/text/debug-5x7-v1.json) is the bundled text fixture for native, WebGL 2, and WebGPU. It defines 5×7 glyphs with a six-pixel advance and eight-pixel line height. The subset is ASCII letters (case-folded), digits, space, `-`, `_`, `.`, `:`, and `/`; other code points render the bundled `?` fallback. Newline starts a new eight-pixel line. Browser hosts decode malformed UTF-8 with the same replacement progression as native before fallback selection.

The fixture is useful for zero-asset HUDs. Games needing an authored face can
use [embedded font decoding](image-assets.md) and [prepared text](authored-text-layout.md).

## Command renderer and conformance

The following host-command details also cover specialised proof-game runtimes.
Ordinary callback games rasterize their Canvas in Zig and upload its RGBA
result; they do not send each Canvas call through the JavaScript command ABI.

The browser command renderer uploads the debug-font fixture once as a nearest-sampled internal glyph atlas. Glyphs preserve active clip/blend/camera state and batch through the normal sprite path on WebGL 2 and WebGPU. A missing or malformed packaged fixture prevents startup with `asset_load_failed:debug_font_v1`.

`push_clip` intersects with the active logical-pixel clip; `pop_clip` restores the previous value. `push_blend(.alpha)` uses source-over alpha, while `.additive` adds alpha-scaled source channels with saturation. A pop without a matching push, or present with unbalanced clip/blend state, is rejected (`UnbalancedRenderState` natively and rejected browser ABI status).

`Camera2D` transforms world coordinates before rasterization. With camera position `(cx, cy)`, zoom `z`, rotation `r`, and viewport `(vx, vy, vw, vh)`, a point `(x, y)` maps to the viewport centre plus `z * rotate((x-cx, y-cy), -r)`. Browser camera setup does not implicitly clip, so browser callers push the logical-pixel viewport clip when needed. `CameraCanvas` and desktop command expansion apply the transform and establish that viewport clip for their own draws; the browser renderer applies the same transform before its WebGL 2 or WebGPU submission.

The backend-neutral fixture is [`stable-core-v1.json`](../../src/fixtures/renderer/stable-core-v1.json). It covers opaque and alpha sprites, plain/multiline/clipped/fallback built-in text, opaque rectangles, source-over and additive blend, nested clips, and a scaled camera transform. Native SDL GPU/OpenGL conformance expands that fixture to deterministic reference pixels. Forced browser WebGL 2/WebGPU runs consume the exact JSON and compare captures with a deterministic CPU reference. The permitted absolute RGBA per-channel delta is one.

Run `zig build test-renderer-conformance`, `zig build test-renderer-cross-backend`, `zig build test-browser-renderer-parity`, and `zig build test-renderer-three-backend`. The three-backend check compares the logical 64×32 capture before presentation chrome, using the same absolute per-channel tolerance of one; a mismatch retains the fixture, desktop raw pixels and OS/architecture/SDL-runtime/driver/shader metadata, browser PNGs, browser command traces, diagnostics, and browser user-agent/platform metadata under `zig-out/diagnostics/renderer-three-backend/`.

Canvas effects and particle reference draws share desktop/browser semantics.
Existing specialised proof-game Wasm runtimes use their direct command ABI.

## Offscreen 2D composition

[`RenderSurface`](render-surfaces.md) is the narrow persistent offscreen
Canvas facility. It uses the same logical-pixel primitives, clip state, blend
state, and presentation-independent color semantics as a normal Canvas, then
composes onto another Canvas with nearest or linear sampling. It is a
CPU-backed, backend-neutral surface—not a public GPU render target—and is
available in headless tests as well as native and browser builds.

[SurfaceCompositor](gpu-surface-composition.md) is an explicit opt-in queue
for scaling and alpha-composing retained CPU surfaces on SDL GPU/WebGL 2.
It has a separate CPU oracle, borrowed-source lifetime and ordering contract.
It does not change the default Canvas renderer.

## Performance guidance

Start at the game's logical resolution and avoid scaling it up in several
CPU passes merely to fill a window; presentation can scale the final image.
Nearest sampling suits pixel art. Large linear-filtered or blended CPU passes
can dominate drawing even when simulation is cheap.

Use [GameProtocol rendering capacity](game-rendering-capacity.md) for the
compiled mixed workload and [CPU surface measurements](surface-composition-performance.md)
for isolated composition costs. The [November 8 CPU/GPU comparison](../reviews/2026-11-08-gpu-surface-composition.md)
records the opt-in compositor's results on one Intel Mac. It supports using
that path for measured composition bottlenecks, while keeping Canvas as the
default. None of these measurements establishes a universal frame rate or a
performance advantage over another framework.

Keep game simulation, CPU drawing, host upload/submission and presentation
pacing distinct when measuring. Submission time does not measure GPU
completion. Benchmark commands and historical distributions live in the linked
measurement guides so ordinary authoring instructions need not track them.
