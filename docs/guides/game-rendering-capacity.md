# GameProtocol rendering capacity

The ordinary GameProtocol host rasterizes Canvas on the CPU, uploads its RGBA
frame, and presents that texture. This experiment measures that complete path
with a compiled portable game, alongside the existing operation benchmarks.
It does not change drawing APIs or introduce performance pass/fail budgets.

## Reproduce

Use the supported Zig toolchain, native SDL/GPU prerequisites, installed Google
Chrome, and the pinned browser automation dependency:

```sh
npm --prefix script/browser-authoring ci --ignore-scripts --no-audit --no-fund
zig build build-render-capacity -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
node script/benchmark_game_rendering.mjs --output zig-out/diagnostics/render-capacity-measured
```

Build everything before measurement; keep other builds and applications idle
during the runner. It runs retained executables and Chromium sequentially.
`--rounds 1` selects a shorter experiment; the default is three rounds. Each
case starts a fresh native process or browser page, discards 120 warm-up frames,
then measures 240 frames. The native process has a 120-second timeout per run;
browser readiness has a matching bound. Quantiles use nearest rank.

Native warm-up includes a one-second initial settling delay and 16 ms per
discarded frame so a newly created desktop window can become presentable.
The retained native frames must each contain the final swapchain blit; a
missing swapchain fails the experiment instead of counting an unpresented
frame as a presentation result. The short correctness run retains the same
settling behavior, and its timing numbers are not performance evidence.

For correctness without a long timing run:

```sh
zig build test-render-capacity -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
```

That path uses four warm-up and eight measured frames. It asserts complete
sample capture, zero game-owned update/draw allocations, healthy runtime and
renderer status, and exact full-frame native/Wasm/WebGL pixel equality in all
four cases. It has no timing thresholds. Nightly macOS validation runs this
check alongside the portable authoring workflows.

`zig build benchmark-game-rendering` builds and measures in one dependency-
ordered command; pass both ReleaseFast options above. The standalone runner
rejects non-ReleaseFast build manifests in measurement mode. It retains
`result.json`, compressed raw warm-up/measured samples, native logs, browser
logs, PNGs and native/browser RGBA references. Binary and relevant source
SHA-256 values identify the actual workload; git status records an uncommitted
checkout. A missing browser or native prerequisite fails with retained evidence.

## Workload

[The compiled game](../../examples/render_capacity_game.zig) uses the same
GameProtocol callbacks in the normal SDL and browser runtimes:

- Fixed 60 Hz simulation computes integer positions for 1,000 entities. It is
  deliberately light simulation, without physics, AI, pathfinding or networking.
- Each draw clears a 320×180 world surface and a transparent 160×90 overlay.
  It draws 1,000 patterned 16×16 sprites to the world: 750 opaque and 250 with
  half alpha plus transparent holes. Placement includes edge clipping and dense
  overdraw. The overlay receives 64 translucent 18×10 rectangles.
- Both surfaces compose across the entire logical Canvas. Three cases use
  nearest composition at 320×180, 640×360 and 1280×720. A fourth uses linear
  composition at 1280×720.
- Twelve prepared two-line labels use Source Sans 3 Regular at 14 pixels,
  authored-font wrapping and center alignment. The label contains narrow/wide
  glyphs and Unicode. Preparation and resource initialization precede timing.
  Labels draw directly on the logical Canvas after composition.
- All cases use a 1280×720-point native window/browser viewport. The runner
  matches the browser backing size to the observed native framebuffer, retaining
  those actual dimensions. A Retina output therefore contains more physical
  pixels than a 1280×720 logical Canvas. Display scanout remains unmeasured.

Sprite and label counts remain fixed as logical resolution increases. This
isolates increased composition, clear and upload work; it is not a test of
proportionally more entities. Font notices travel with the benchmark bundle.

## What each clock includes

| Recorded stage | Meaning |
| --- | --- |
| Game `update_ms` | Sum of position-update callback work in a presented frame; zero or several fixed updates are possible. |
| Game `sprites_ms` | Canvas/surface clears, 1,000 sprite draws and 64 overlay rectangles. |
| Game `composition_ms` | Two full-Canvas CPU surface compositions. |
| Game `text_ms` | Twelve prepared authored-label draws. |
| Game `draw_ms` | The above draw work plus its small timer boundaries; no decoding/layout preparation. |
| Native `host_update_ms`, `host_draw_ms` | Existing SDL callback boundaries, including the workload's observation overhead. Native additionally clears the main Canvas before the callback. |
| Native `upload_present_ms` | CPU staging/upload, GPU command encoding/submission, swapchain acquisition and any driver waits. These operations are not individually separated by the native reporter. |
| Browser `upload_ms` | CPU duration of the host canvas-upload call, including WebGL texture update and sprite enqueue. It may include driver blocking. |
| Browser `present_ms` | CPU duration of the host final flush/presentation call; not GPU completion. |
| `frame_ms` | Native loop entry through present, or the browser scheduled callback's CPU duration. Native can block on swapchain pacing; browser CPU work can return before the next RAF. |
| `interval_ms` | Time between loop/callback starts; includes scheduling and waiting. Browser additionally retains RAF timestamp intervals. |

Native extends its existing private opt-in reporter with
`UP_NATIVE_TIMING_SAMPLES=1`: a bounded 4,096-frame buffer is allocated before
the loop and serialized after it. The game retains at most 1,024 samples; the
runner uses 360 and rejects dropped samples. There is no timed-frame file I/O.
Browser adapters wrap existing imports and RAF callbacks without CDP tracing.
Clock overhead is retained, not subtracted. Browser clock quantization is
recorded; values below that resolution can round to zero.

The existing rendering benchmark's counting allocator observes allocations
through the game's resource allocator. All frame samples, including warm-up,
must report zero allocation events/bytes. This does not establish zero SDL,
driver, browser JavaScript or GPU allocation. Wasm memory sizes at warm-up/end
provide additional high-water evidence, not a JavaScript allocation profiler.
Prepared layout drawing and composition keep their existing allocation-free
ownership contracts.

GPU fences, `finish`, timer queries, screenshots, hashes and readbacks are
excluded from timed frames. The runner freezes simulation at tick 37 afterward
and compares full native CPU pixels with the actual Wasm/WebGL output. There
is no claim about completed GPU time, physical display pacing, input latency,
or native GPU readback from this comparison.

## Relation to existing evidence

`benchmark-rendering` remains the operation-level Canvas/RenderSurface tool;
`benchmark-surface-composition` and its alternating before/after runner remain
the focused composition tools. `benchmark-workloads` and the browser workload
catalog measure repeated command-buffer submission with initialization removed.
Those tools provide useful attribution, but do not run this ordinary Canvas
GameProtocol frame through its host. Their historical CPU-only measurements
must not be presented as whole-game frame times.

See the [dated rendering audit follow-up](../reviews/2026-11-07-gameprotocol-rendering-capacity.md)
for the measured results, practical recommendations and next implementation
decision. This experiment does not benchmark raylib, Ebitengine or LÖVE.
