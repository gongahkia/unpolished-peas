# CPU surface composition: measurement and validation

`Canvas.drawSurface` samples CPU pixels and blends them into another CPU
Canvas. The November 6, 2026 change caches the work shared by destination rows
in linear filtering. It preserves the existing pixel contract; it does not
move Canvas drawing to the GPU or change the public API.

## Reproduce the workloads

Use Zig 0.15.2. The focused benchmark needs no SDL, window or browser:

```sh
zig build -Doptimize=ReleaseFast -Dwith_sdl=false \
  benchmark-surface-composition --verbose -- --rounds 7
zig build -Doptimize=ReleaseFast -Dwith_sdl=false \
  benchmark-surface-composition -- --case pattern_linear_320x180_to_1280x720 --rounds 7
```

The [fixed workload catalog](../../src/surface_composition_workloads.zig)
includes the original solid nearest/linear surface cases, patterned opaque
and partially transparent upscales, tinted/additive/clipped composition,
downscaling, odd ratios, a one-pixel-wide source, and linear 1:1 composition.
The [benchmark](../../src/surface_composition_benchmark.zig) emits JSONL with
all dimensions, origin, clip, tint, blend, visible pixel count, iteration count,
pixel hash and allocation counters. Setup, procedural source population,
destination clear, hashing and JSON output happen outside the timed region.

Each sample warms up with four complete draws, then measures
`ceil(48 * 1024 * 1024 / visible_pixels)` draws, bounded to 8–8192 iterations.
Every current case reaches the 48 Mi visible-pixel target. A compiler memory
barrier follows each draw; it does not hash pixels inside the timed loop.
The destination is not cleared between draws, including alpha/additive cases.
These are repeated-composition workloads, not varied complete game frames.
Elapsed nanoseconds divided by iterations give wall-clock CPU composition time,
including scheduling delays. This is not CPU thread time.

To compare changes, retain the actual executable printed by `--verbose`
**before editing Canvas**, then build and retain the new executable. Run them
serially on the same machine:

```sh
python3 script/compare_surface_composition.py \
  zig-out/performance/surface-2026-11-06/before-surface-composition \
  zig-out/performance/surface-2026-11-06/after-surface-composition \
  --baseline zig-out/performance/surface-2026-11-06/before.jsonl \
  --rounds 7 --output zig-out/performance/surface-2026-11-06/paired.json
```

Those binary paths describe the retained local run, not committed executables.
For a new experiment capture its baseline JSONL and binaries in a new directory.
To rebuild the historical algorithm, make an isolated copy of the current
checkout (excluding `.git`, `.zig-cache` and `zig-out`), replace only its
`src/canvas.zig` with
`git show 48dced2ca325392ae490e636068be316780cc789:src/canvas.zig`, and build
the same focused benchmark there. This retains the identical harness and
workloads while restoring the measured renderer. Its Canvas SHA-256 must match
the recorded original source. Keep the working renderer intact; binaries from
different machines are not a valid paired comparison.
The comparison script runs each case before/after in even pairs and after/before
in odd pairs. It rejects any change to workload parameters, iteration counts,
pixel hashes or zero-allocation invariants. It retains every observation,
median, range, median absolute deviation (MAD), and median paired speedup.
Do not compile, profile or run other tests alongside the measurements.

## Recorded experiment

The [measurement record](../../benchmarks/surface-composition/2026-11-06-macos-x86_64.json)
contains the seven paired samples for all twelve cases, hardware/toolchain,
source and executable hashes, workload parameters and power observations.
It is an experimental record, not a new performance budget. Existing budget
and workload-baseline files are unchanged.

The baseline is commit `48dced2ca325392ae490e636068be316780cc789`, captured before
changing Canvas. Hardware is an Intel Core i5-8279U at its reported 2.40 GHz,
4 physical / 8 logical cores, 8 GiB RAM; macOS 15.7.7 (24G720), x86_64;
Zig 0.15.2. Both focused binaries use `-OReleaseFast` for their root and Peas
modules, native target defaults and `-Dwith_sdl=false`. The verbose compiler
commands are retained with the raw local artifacts. The initial power report
was battery power at 100%, discharging. Power management and CPU frequency
were not fixed; alternating binaries controls some drift, not every source
of noise. No measurements or outliers were discarded.

| Workload | Before median (ms) | After median (ms) | Median paired speedup |
| --- | ---: | ---: | ---: |
| `surface_1to1_nearest` | 0.084 | 0.082 | 1.02× |
| `surface_160x90_to_1280x720_nearest` | 1.613 | 1.604 | 1.01× |
| `surface_320x180_to_1280x720_nearest` | 2.255 | 2.080 | 1.00× |
| `surface_160x90_to_1280x720_linear` | 23.840 | 7.393 | 3.29× |
| `surface_320x180_to_1280x720_linear` | 24.305 | 8.224 | 2.96× |
| `pattern_linear_320x180_to_1280x720` | 23.914 | 8.461 | 2.88× |
| `alpha_linear_320x180_to_1280x720` | 31.368 | 13.305 | 2.34× |
| `tinted_additive_linear_clipped` | 29.524 | 15.595 | 1.88× |
| `downscale_linear_640x360_to_317x179` | 1.487 | 1.031 | 1.49× |
| `odd_alpha_linear_37x23_to_1001x563` | 21.142 | 10.156 | 2.08× |
| `thin_alpha_linear_1x180_to_1280x720` | 31.227 | 12.255 | 2.50× |
| `pattern_linear_1to1` | 1.527 | 0.327 | 4.92× |

All nine linear cases improved in every paired observation. The three nearest
cases have paired ratios close to one; their small median differences do not
establish an improvement. The nearest implementations were unchanged. Full
distributions and MADs are retained to expose scheduling and thermal variance.
The two separately collected seven-round blocks also favored every linear
case, but the alternating pairs above are the primary comparison.

## Bottleneck and implementation

The unchanged benchmark was also run through macOS sampling:

```sh
zig-out/performance/surface-2026-11-06/before-surface-composition \
  --case surface_320x180_to_1280x720_linear --rounds 8 > profile-run.jsonl &
profile_pid=$!
/usr/bin/sample "$profile_pid" 3 1 -file before-sample.txt
wait "$profile_pid"
```

The main-thread call tree placed 2144 of 2151 samples in `Canvas.drawSurface`
during linear composition. The sampler resolves inlined work to that function;
it does not provide a reliable separate percentage for each lerp or divide.
Source inspection showed the same X mapping and rounded horizontal color
interpolation repeated for each destination row.

Linear composition now processes at most 256 columns at a time. It calculates
their X mappings once, caches two horizontally interpolated source rows, and
reuses or swaps those rows as the Y mapping advances. Vertical interpolation,
tint and blending still operate on each destination pixel. Exact interpolation
endpoints skip arithmetic with the same byte result.

The explicit scratch is 5 KiB: 256 column records of 12 bytes and two arrays of
256 four-byte colors. This is fixed stack storage, with additional bounded
locals; it is not a claim about the compiler's complete stack frame. There is
no heap allocation, retained cache, additional owner or width-sized scratch.
Rounded horizontal `u8` colors are cached before vertical interpolation; a
single mathematically equivalent bilinear expression would change pixels at
rounding boundaries and is deliberately not substituted.

## Correctness checks

```sh
zig build test-surface-composition test-browser-surface-composition \
  -Dwith_sdl=false --summary all
script/test_browser_surface_composition.sh
```

The [independent scalar reference](../../src/surface_composition_reference.zig)
does not use the production sampling, interpolation, tint or blend helpers.
The [shared suite](../../src/surface_composition_conformance.zig) compares exact
RGBA pixels and logical trace hashes for 554 cases: every benchmark workload,
chunk boundaries, tiny/thin sources, 512 seeded cases, and huge destination
rectangles clipped to small canvases. It covers both filters, up/down/odd-ratio
scaling, negative origins, tint, alpha extremes, both blend modes and nested
clips, with surrounding draws to check ordering. Normal draws are checked for
zero successful allocation/growth events. Opt-in CanvasTrace owns its pre-existing
capture allocations separately.

The 554-case pixel/trace aggregate was captured on the original implementation
before optimization: `716431564172485137`. Debug and ReleaseFast native tests,
Node/Wasm and the real Chromium check require that unchanged value. A separate
2×2-to-3×3 half-rounding assertion explicitly requires staged byte rounding.
The Wasm test executable uses ReleaseFast; its imported browser core follows
the existing browser default, ReleaseSmall. Real-browser logs retain the
user agent and native/Wasm hashes under `zig-out/diagnostics/surface-composition`.
The native differential tests also run under `zig build test`; CI runs both
Node/Wasm and real-browser checks.

The local real-browser run used Headless Chromium 157.0.0.0 on MacIntel and
passed the frozen hash and staged-rounding check. The broader preservation
check was:

```sh
zig build test test-core-api test-support test-replays test-starter \
  test-starter-template test-dogfood test-lantern-leap test-docs docs \
  test-browser-runtime test-browser-protocol-host test-browser-wasm-host \
  test-browser-input-v2 test-browser-asset-collection \
  test-browser-surface-composition -Dwith_sdl=false -j2 --summary all
zig build test-sdl check-examples test-browser-render-surfaces -j2 --summary all
zig fmt --check build.zig src/canvas.zig src/render_benchmark.zig \
  src/surface_composition_benchmark.zig src/surface_composition_conformance.zig \
  src/surface_composition_reference.zig src/surface_composition_workloads.zig src/docs.zig
git diff --check
```

The headless/public API/replay/docs/browser-host suite passed 94/94 build steps
and 397/397 tests. The SDL/examples/browser-surface check passed 46/46 steps
and 63/63 tests. Existing API snapshots and pixel/replay/trace assertions
remain unchanged. The full rendering benchmark completed all 96 workloads
before and after with matching workload/iteration parameters and zero drawing
allocations. Its single-run linear 320×180-to-1280×720 observation was
21.758 → 7.666 ms; the paired focused measurements above carry the stronger
statistical evidence.

## Practical limits

These times cover CPU sampling and blending only. There is no frame upload,
presentation, browser submission, GPU completion, audio or simulation work in
the timing. Browser execution is a correctness check, not a browser speed
claim. The existing full `benchmark-rendering` workloads remain a separate
cross-check; their timings must not be mixed with the focused harness.

Nearest/integer scaling remains the economical choice for low-resolution
pixel art. Large alpha or tinted compositions still cost milliseconds and
multiple full-size passes add up. A faster draw alone does not guarantee a
60 Hz game, and 1280×720 is not 1920×1080. Results on one Intel Mac and one
Chromium version establish neither Apple Silicon/Windows/Linux performance
nor Safari/Firefox correctness. `Renderer2D` retains its separate GPU contract;
this change does not add general GPU offscreen surfaces or effects.
