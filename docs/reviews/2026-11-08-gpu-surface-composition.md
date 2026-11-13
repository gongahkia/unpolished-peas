# Portable GPU surface-composition follow-up — November 8, 2026

This follows the [framework audit](2026-11-04-framework-value-proposition-audit.md)
and [complete GameProtocol CPU rendering experiment](2026-11-07-gameprotocol-rendering-capacity.md).
The experiment keeps ordinary Canvas rasterization and adds an explicit
SDL GPU/WebGL 2 scaling/alpha-composition path. The default renderer remains
CPU Canvas; browser/platform preview status is unchanged.

## Baseline and implementation

The CPU baseline was reproduced before implementation, with three rounds at
each of four workload configurations on native ReleaseFast and real Chromium
WebGL 2. The [retained baseline](../../benchmarks/surface-gpu/2026-11-08-cpu-baseline.json)
and [compressed samples](../../benchmarks/surface-gpu/2026-11-08-cpu-baseline.samples.json.gz)
record 24 successful runs, exact native-CPU/browser pixels and zero game
update/draw allocation events. Commit `ea6467a8` records that pre-change evidence.

`up.graphics.SurfaceCompositor` owns bounded metadata and borrows stable
`RenderSurface` sources. Games queue scaled layers and one optional Canvas
marker, then call `Renderer2D.composeSurfaces`. Sources upload their current
pixels every submitted frame, including direct writes after queue construction.
There is no dirty-flag synchronization burden or mutable use of the existing
immutable image cache. `drawCpu` evaluates the same order without allocating.
The [guide](../guides/gpu-surface-composition.md) and generated
[call reference](../api/drawing.md#graphics-SurfaceCompositor) define lifetimes,
memory bounds, unsupported operations and foreground alpha storage.

The first real native fixture exposed a nearest-sampling mismatch: ordinary
GPU sprite sampling chooses pixel centers, while Canvas uses edge-aligned
integer division. The surface fragment shader now implements that integer
mapping explicitly. Its SPIR-V, MSL and HLSL artifacts reproduce byte for byte
with glslang 16.6.0 and SPIRV-Cross 1.4.363.0; `spirv-val` accepts the SPIR-V.
MSL executes through SDL GPU/Metal in these checks. Vulkan and D3D execution
have not been verified on native hardware.

## Correctness and resource evidence

The [retained correctness record](../../benchmarks/surface-gpu/2026-11-08-correctness.json)
contains browser/renderer metadata, all fixture deltas, rollback observations
and 169 pixel-reference/capture hashes. Full artifacts remain under
`zig-out/diagnostics/surface-gpu/`, and the nightly job retains that directory.

| Host | Observed checks | Result |
| --- | --- | --- |
| SDL GPU / Metal, Intel macOS | 12 fixtures at 48×32 and 64×40; all four mixed-game configurations | Small-fixture maximum channel delta 3; mixed workload delta 1/1/1/3 against the new CPU oracle and 2/2/2/3 against the original CPU path |
| Chrome 157.0.8103.38 / WebGL 2 | Same 12 fixtures, plus mixed-workload CPU/GPU modes | Small-fixture maximum delta 3; mixed GPU 1/1/1/3 against CPU oracle, original CPU 2/2/2/3; legacy CPU frames exact |
| Firefox 158.0 / WebGL 2 | Same 12 fixtures and resource/recovery checks | Maximum delta 3; opaque nearest and CPU fallback exact |
| Safari 18.6 / WebGL 2, real Safari WebDriver | Same 12 fixtures and resource/recovery checks | Maximum delta 3; opaque nearest and CPU fallback exact |

Each browser passes creation-failure rollback/retry, twelve repeated
release/generation transitions, direct source mutation, actual WebGL context
loss/restoration, backing-size change and shutdown. Shutdown leaves zero
game GPU resources and zero scheduled frames. Safari retains the independent
PNG probe and independent renderer readback. The new checks share the existing
browser adapters and contain no Chromium CDP dependency.

Native tests fail each of six source texture/transfer/vertex creation
boundaries, check cleanup and retry, and recreate/resize the presenter.
Source uploads are deduplicated within a frame. No source address or compositor
owner identifier enters deterministic pixel hashes. Existing CPU goldens and
existing renderer tolerances are unchanged. The new alpha/linear fixtures
permit at most six channel values to account for their interpolation and
repeated GPU rounded versus CPU floored blending. This does not promise a
six-value bound for an arbitrary 128-draw accumulation.

The ordinary browser runtime contract advances from 6 to 7 with one appended
callback; all previous callbacks/exports remain. A preserved, hash-matched
ABI 6 baseline Wasm binary also instantiated, initialized, drew and shut down
with the new host. New Wasm must ship with the matching host. Input layouts
and replay formats stay unchanged.

## Paired CPU/GPU measurements

The [retained report](../../benchmarks/surface-gpu/2026-11-08-cpu-gpu-comparison.json)
and [compressed raw samples](../../benchmarks/surface-gpu/2026-11-08-cpu-gpu-comparison.samples.json.gz)
contain all 48 successful runs and 17,280 warm-up/measured game samples.
The sample archive SHA-256, source hashes and binary hashes were checked, and
every median/p95/p99 was recomputed from its retained raw samples.

The final run used Zig 0.15.2, native/Wasm ReleaseFast, Node 24.19.0 and
Chrome 157.0.8103.38 on Intel macOS 15.7.7: i5-8279U at nominal 2.40 GHz,
8 GiB RAM and Iris Plus 655. Native used SDL GPU/Metal; Chromium used WebGL 2
with ANGLE Metal on the same GPU. A 1280×720-point/CSS output used the same
2560×1440 backing framebuffer on both hosts. The machine was on AC power.

The existing mixed game draws 1,000 patterned 16×16 sprites (750 opaque,
250 translucent) into 320×180, 64 alpha rectangles into 160×90, two scaled
layers and twelve prepared Source Sans labels. Each case uses 120 warm-up
and 240 measured frames, repeated three times. CPU/GPU pairs run serially,
with order reversed in round two; all native runs precede Chromium. Game
update counts are retained because fixed-step catch-up can differ with frame
duration. Output comparison freezes the same tick 37, outside timing.

Values below are ranges across the three individual rounds, in milliseconds.
They are not pooled percentiles or averages of percentiles. Host frame time
includes native presentation waits; browser host frame time is CPU callback
work, not a completed-GPU or physical-display measurement.

| Host / logical size / filter | Mode | Draw median | Draw p95 | Host frame median |
| --- | --- | --- | --- | --- |
| Native 320×180 nearest | CPU | 3.014–3.126 | 3.575–3.924 | 16.659–16.673 |
| Native 320×180 nearest | GPU | 2.272–2.454 | 2.716–3.118 | 16.656–16.669 |
| Native 640×360 nearest | CPU | 3.935–4.483 | 5.139–5.298 | 16.661–16.667 |
| Native 640×360 nearest | GPU | 2.355–2.446 | 2.853–3.081 | 16.657–16.663 |
| Native 1280×720 nearest | CPU | 8.262–9.486 | 10.279–12.372 | 16.658–16.667 |
| Native 1280×720 nearest | GPU | 2.040–2.437 | 2.845–3.131 | 16.662–16.671 |
| Native 1280×720 linear | CPU | 21.505–25.835 | 27.809–34.677 | 22.263–26.730 |
| Native 1280×720 linear | GPU | 2.026–2.599 | 2.521–3.209 | 16.662–16.667 |
| Chromium 320×180 nearest | CPU | 3.200–4.000 | 3.600–5.100 | 3.500–4.300 |
| Chromium 320×180 nearest | GPU | 3.000–3.400 | 3.800–4.200 | 3.400–3.800 |
| Chromium 640×360 nearest | CPU | 6.200–7.000 | 8.100–8.500 | 6.500–7.300 |
| Chromium 640×360 nearest | GPU | 2.500–3.000 | 3.900–4.000 | 3.000–3.500 |
| Chromium 1280×720 nearest | CPU | 12.700–13.800 | 13.900–19.400 | 13.500–14.700 |
| Chromium 1280×720 nearest | GPU | 3.000–3.500 | 4.300–4.500 | 4.100–4.600 |
| Chromium 1280×720 linear | CPU | 123.600–129.600 | 127.900–212.200 | 124.500–130.500 |
| Chromium 1280×720 linear | GPU | 3.500–3.800 | 4.400–5.000 | 4.700–5.100 |

GPU-mode native queue construction had approximately 0.001 ms medians.
Browser queue construction rounded to zero at the observed 0.1 ms clock
resolution; that does not establish free work. Actual GPU composition is in
host submission, outside the game draw timer. Prepared text remains CPU
rasterized. Native light simulation medians were 0.001–0.002 ms; browser
update medians rounded to zero. The existing sprite/text stages and complete
per-round p99/max distributions are retained in the report.

| Logical case | Native CPU upload/present median | Native GPU upload/present median | Browser CPU upload-call median | Browser GPU upload-call median |
| --- | --- | --- | --- | --- |
| 320-nearest | 13.388–13.467 | 14.072–14.220 | 0.100–0.100 | 0.100–0.100 |
| 640-nearest | 12.037–12.629 | 13.993–14.078 | 0.200–0.200 | 0.200–0.200 |
| 1280-nearest | 6.793–8.024 | 13.654–14.125 | 0.600–0.700 | 0.800–0.900 |
| 1280-linear | 0.420–0.470 | 13.537–14.089 | 0.700–0.800 | 0.900–0.900 |

Native upload/present includes swapchain pacing/driver waits. GPU-mode
values near 14 ms mostly reflect time left waiting after cheaper game drawing,
not measured GPU execution. Browser surface-draw submission medians were
0.1 ms; final-present medians often rounded to zero in GPU mode, versus
0.1 ms in CPU mode. No GPU completion timers or physical scanout measurements
were collected. Readbacks, PNGs and compact base64 automation transfer occur
after timed frames.

All 17,280 recorded game samples reported zero allocator events and allocated
bytes during update/draw. Wasm memory stayed at its warm-up size in every
case: 6,029,312 bytes at 320×180, 6,815,744 at 640×360 and 9,961,472 at
1280×720, in both modes. GPU mode retained three browser game texture handles;
CPU mode retained zero such handles (its Canvas texture is host-internal).
Every browser frame observed exactly one CPU-mode or three GPU-mode texture
uploads. Texture bytes/frame were respectively 230,400/518,400 at 320×180,
921,600/1,209,600 at 640×360 and 3,686,400/3,974,400 at 1280×720. Native
byte counts are calculated from the same fixed full-source upload code, not
independent driver counters. Vertex transfers and internal driver staging
are excluded. SDL/driver/JavaScript allocation events remain unmeasured.

Each of the 24 browser runs passed actual WebGL readback comparison. Legacy
CPU-mode pixels were exact. GPU nearest frames differed by at most one channel
value against the queue CPU oracle and two against the original immediate
CPU path; linear differed by at most three against either reference. These
match the separate actual-native mixed-workload readbacks.

Two earlier attempts were intentionally excluded when unrelated Bun/Vitest
suites overlapped timing. Their logs/reports remain in
`zig-out/diagnostics/surface-gpu/comparison-noisy-excluded/` and
`comparison-vitest-excluded/`. The final run waited for those suites to finish
and ran no Peas builds/tests concurrently. Desktop/VM activity and brief
other Node work remained. There was no CPU affinity, frequency/temperature
control or exclusive-machine isolation. The large CPU linear tails, including
a per-round browser draw p99 as high as 495.9 ms, are retained and unexplained;
do not interpret medians as tail-latency guarantees.

The pre-change baseline is evidence that the original bottleneck existed.
It is not the denominator for a clean implementation-only speedup claim:
both final modes share the new host texture snapshot reuse/texSubImage2D
path and the same instrumentation/revision. No peer framework was measured.

## Rendering decision and next goal

Keep this facility opt-in. It provides useful CPU headroom for the measured
large scaled layers, especially linear composition. At 320×180, Chromium
CPU/GPU medians overlap and their first-round draws tie at 3.2 ms. Native
nearest cases remain presentation-paced near 16.7 ms in both modes. Neither
observation justifies a default-renderer switch or a universal frame-rate
claim. The experiment does not measure a general GPU sprite/primitive path,
so it does not justify a broader rasterizer rewrite.

The measurement and focused GPU surface prototype gaps from the audit are
now resolved. Earlier generated-project, authored-asset/font, input, audio
lifetime and browser-authoring evidence remains applicable. Other native
hardware, physical input/audio checks and larger-game services remain open.

One concrete next implementation goal is a reproducible custom-shader asset
build workflow: accept a binding manifest and supported source inputs,
generate/validate the existing native/browser artifacts with one command, and
prove one portable custom-effect example. This addresses the remaining documented
authoring burden without treating these composition results as evidence for
new loading, localization or audio subsystems.

## Validation already observed

The broad ReleaseFast core/API/replay/docs/Wasm command passed 125/125 build
steps and 447/447 tests. The compositor suite additionally passed 35/35 tests
in Debug. Generated API recipes execute on native and Wasm. The existing
scalar-reference surface suite retains all 554 exact pixel/trace cases.
Native GPU/readback tests, existing renderer goldens and all compiled examples
passed 53/53 build steps and 132/132 tests with:

```sh
zig build test-surface-gpu-native test-renderer-conformance check-examples -Doptimize=ReleaseFast -j1 --summary all
```

The immutable external archive consumer's untouched generated game passed
`zig build`, `zig build test`, `zig build web` and `zig build package` from an
external directory containing spaces.

Focused commands:

```sh
zig build test-surface-compositor test-core-api -Doptimize=ReleaseFast
zig build test-surface-compositor -Dwith_sdl=false -j1 --summary all
zig build test-surface-gpu-native -Doptimize=ReleaseFast -j2 --summary all
zig build test-surface-gpu-browser -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
node script/benchmark_game_rendering.mjs --modes cpu,gpu --verify-only --output zig-out/diagnostics/surface-gpu/capacity-check-final
zig build test-starter-external-web -Doptimize=ReleaseFast -j1 --summary all
zig build build-render-capacity -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
node script/benchmark_game_rendering.mjs --modes cpu,gpu --output zig-out/diagnostics/surface-gpu/comparison-compact
node script/browser-authoring/contract.mjs
node script/test_browser_webgpu.mjs
zig fmt --check build.zig src examples
actionlint .github/workflows/nightly.yml
git diff --check
```

The complete core/API/replay/docs/Wasm regression command was:

```sh
zig build test test-core-api test-support test-replays test-scenes test-docs docs test-docs-recipes check-public-import-inventory test-browser-runtime test-browser-wasm-host test-browser-protocol-host test-browser-host test-browser-contract test-browser-render-surfaces test-browser-webgpu test-surface-composition test-browser-surface-composition -Dwith_sdl=false -Doptimize=ReleaseFast -j2 --summary all
```

The compact readback change additionally passed the same sixteen mixed native
and Chromium CPU/GPU cases with `--verify-only --output
zig-out/diagnostics/surface-gpu/capacity-compact-check`; existing array callers
remain unchanged. Contract coverage verifies exact RGBA bytes across the
base64 chunk boundary and rejects invalid encodings. This transport change
is commit `f80fe558` and runs entirely outside timed frames.
After that change, the full shared Chromium/Firefox/Safari fixture passed
again (12/12 build steps). Final documentation/link validation passed 43/43
steps and 36/36 tests. The correctness record's hashes reflect those latest
captures; PNG encoding can vary between sessions while raw RGBA stays equal.

README.md is unchanged. No license, release or publishing decisions are part
of this work. The implementation is commit `d967c9f5`; retained native and
three-browser correctness evidence is commit `28e3311f`.

## Remaining limits

CPU sprites/primitives/text and full source uploads remain. OpenGL and WebGPU
explicitly reject the new queue. Sources and compositor addresses must remain
stable through presentation. The host Canvas contains the CPU foreground,
not the completed GPU frame. GPU completion, physical presentation pacing,
driver/JavaScript allocation events and other machines remain unmeasured.
Apple Silicon, native Linux/Vulkan and Windows/D3D hardware still require
evidence; Firefox/Safari checks here establish correctness, not performance.
This work does not add shaping, asynchronous loading, richer audio or a
portable custom-shader authoring language.
