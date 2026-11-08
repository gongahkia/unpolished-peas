# Opt-in GPU surface composition

`up.graphics.SurfaceCompositor` scales and alpha-composes retained CPU
`RenderSurface` layers on native SDL GPU and browser WebGL 2. Ordinary sprites,
primitives and authored text still rasterize into Canvas on the CPU. The
default renderer and immediate `Canvas.drawSurface` behavior stay unchanged.
Treat this as an opt-in prototype, with the existing platform preview status.

## Use and order

Create the compositor and surfaces in `Game.init`, using the game allocator.
Retain pointers only after the surfaces occupy stable game-owned storage.
The [compiled API recipe](../api/drawing.md#explicit-composition-recipe)
shows setup, foreground alpha, ordering and allocation-free CPU evaluation.
The [portable compiled fixture](../../examples/surface_composition_game.zig)
also draws prepared proportional authored text.

In each draw callback, draw into the retained surfaces and host Canvas, call
`scene.beginFrame(opaque_background)`, queue `drawLayer(handle, options)` and
optionally `drawCanvas()`, then submit:

```zig
try (try ctx.requireRenderer2D()).composeSurfaces(&self.scene.?);
```

The host clears the final logical target to the scene background, executes
the queued layers in order and places the final host Canvas at its marker.
Put that marker first, between layers or last. It may appear once; omit it
when the host Canvas should not contribute. Canvas contents are sampled
after the draw callback, including drawing performed after submission.
The marker does not capture an intermediate Canvas state. Existing advanced
queues execute after this base frame, then existing post passes.

For transparent foregrounds, save `canvas.preserve_alpha`, set it to `true`,
clear to `Color.transparent`, draw text/primitives normally, then restore the
flag. This explicitly stores straight alpha over transparent pixels and
avoids opaque dark text fringes. Its default is `false`; existing `Color.over`
and Canvas drawing retain their historical behavior. Additive Canvas drawing
retains its old opaque-output behavior even when this flag is set.

## Sampling and unsupported operations

Layer options contain the existing `SurfaceDrawOptions`, an optional logical
clip and `.alpha` blend. Tint multiplies sampled RGBA in byte space before
source-over blending. Clips affect destination writes, including negative or
entirely offscreen rectangles. Nearest uses Canvas's edge-aligned integer
mapping `floor(destination_offset * source_size / destination_size)`.
Linear uses clamped hardware interpolation at pixel centers. CPU linear
sampling rounds intermediate rows to bytes; GPUs may interpolate and blend
with different precision. The shader quantizes its sample and tint before
blending to bound these differences.

Opaque nearest fixtures and the CPU fallback remain exact. Alpha/linear
fixtures allow an absolute per-channel delta of at most 6 for the tested
three/four-layer stacks; this accounts for interpolation and repeated
floor-versus-rounded source-over operations. This is a conformance bound for
these fixtures, not a universal error bound for arbitrary 128-draw stacks.
The old exact CPU goldens and existing one-channel renderer tolerances remain
unchanged. For deterministic pixel queries, evaluate `drawCpu` into a separate
Canvas. There is no public portable GPU readback API in this prototype; the
host Canvas contains the CPU foreground, not the completed GPU frame.

The final target must be opaque. Additive composition, feedback, zero-sized
destinations, oversized rectangles and invalid clips fail explicitly.
There is no source crop, rotation, custom material, mip chain or GPU rendering
into these source surfaces. Native OpenGL rejects the opt-in queue with
`SurfaceCompositionGpuUnavailable`; browser WebGPU returns unavailable for
the surface callback. Choose a supported host or explicitly call `drawCpu`
into a separate Canvas and present that result through the ordinary path.

## Ownership, synchronization and bounds

The game owns source surfaces, the compositor and its allocator. Retaining
does not copy pixels or transfer ownership. Their addresses must remain stable
and alive through presentation; do not copy the compositor or move its sources
while retained. Use them on the game thread. Every distinct used source uploads
its latest pixels on each submitted frame, including direct writes after queue
construction. There are no dirty flags and no silent stale immutable-image
cache entries. Source writes must finish before host presentation.

Release a layer before destroying or replacing its source. Resizing a retained
surface is forbidden and detected while it is live; release and retain a new
surface instead. Handles include owner and generation; stale and cross-owner
handles fail. Releasing a queued layer invalidates that queue, so begin a new
frame before submitting again. Deinit after the last presentation, before
freeing the sources. Host textures are reclaimed on subsequent presentation
without the scene, when generations/owners change, or at host shutdown.

Initialization reserves all queue metadata. Defaults are 8 retained slots,
32 draws and 16 MiB retained-source bytes; configurable limits are 32 slots,
128 draws and 64 MiB source bytes. Each source and the logical output must be
at most 4096×4096. Destination extents are 1–65535, with checked signed bounds.
`retain` accounts each retained slot, including repeated retains of one source.
The Canvas marker uses one draw but not a source slot/budget.

Queue construction and CPU evaluation allocate nothing after initialization.
Native GPU storage adds at most one RGBA8 texture and matching upload buffer
per cached source, plus two bounded vertex buffers (`draw_capacity * 6 * 32`
bytes each). Fixed native quad scratch is 24 KiB. The main Canvas upload and
existing two logical color targets are additional engine storage. Browser
textures retain an owned CPU upload snapshot for context restoration, reused
with `texSubImage2D` on same-size updates. Browser host arrays, driver staging,
swapchain storage and driver-internal cycling are outside the game allocator
and source budget; they are not claimed to allocate zero bytes.

## Build and validation

```sh
zig build web-surface-gpu -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast
zig build test-surface-compositor test-core-api -Doptimize=ReleaseFast
zig build test-surface-gpu-native -Doptimize=ReleaseFast -j2 --summary all
zig build test-surface-gpu-browser -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
zig build test-render-capacity-gpu -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
```

Serve `zig-out/surface-gpu` over HTTP and select `?renderer=webgl2`. The fixture
exports `surface_probe_case(0..11)` for automated case selection; it is a
correctness example, not a game. The shared browser adapter retains real
Chromium, Firefox and Safari checks, independent WebGL/PNG probes, renderer
metadata, RGBA/PNG captures and failure artifacts. Use
`-Dsurface-browsers=chromium,firefox` for an explicit subset; omitted browsers
are not validated. Missing prerequisites produce unverified results.

Native checks read back actual Metal/GPU output at two logical sizes and all
four mixed-workload configurations. They inject creation failures and retry
with no partial resources. Browser checks exercise source mutation, generation
churn, creation failure, repeated release, actual context loss/restoration when
the extension is available, backing resize and shutdown. Shader compilation
requires glslang and SPIRV-Cross only when regenerating committed artifacts.
Normal consumer builds use the checked-in SPIR-V, MSL and HLSL artifacts.

The browser runtime contract intentionally advances from 6 to 7, appending
`up_host_gl_surface_draw` after all 37 prior callbacks. Existing export names
and callback signatures remain. The JavaScript host's independently numbered
`AbiVersion` advances from 5 to 6. Package matching Wasm and host modules;
an older host cannot execute the new composition import. Input ABI v1/v2 and
replay formats are unchanged.

## Measuring the decision

Build first, then measure without concurrent builds/tests:

```sh
zig build build-render-capacity -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
node script/benchmark_game_rendering.mjs --modes cpu,gpu --output zig-out/diagnostics/surface-gpu/comparison
```

This reuses the [mixed GameProtocol workload](game-rendering-capacity.md):
1,000 sprites, prepared authored text, alpha drawing and two scaled layers.
The same native executables and Wasm binary select CPU/GPU modes. Cases pair
the modes and reverse order on even rounds; native and Chromium runs are
serial. Reports retain three rounds, 120 warm-up and 240 measured frames per
case. The game `composition_ms` becomes queue construction in GPU mode; GPU
composition happens in the host. Browser `surface_submit_ms` measures draw
encoding/submission callbacks; texture upload is recorded separately.
Native upload and presentation remain combined with possible pacing waits.
Neither submission time nor RAF/swapchain intervals measure GPU completion
or physical display scanout. Captures and readbacks happen outside timing.

The [dated audit follow-up](../reviews/2026-11-08-gpu-surface-composition.md)
records observed results and the recommendation;
this API does not promise a frame rate or superiority over another framework.
