# GameProtocol rendering capacity — November 7, 2026

This follows the [November 4 framework audit](2026-11-04-framework-value-proposition-audit.md).
It measures the ordinary CPU Canvas GameProtocol path through native SDL GPU
and real Chromium WebGL 2. It introduces no renderer subsystem or public API.

## Evidence and method

The [capacity guide](../guides/game-rendering-capacity.md) specifies the compiled
workload and timing boundaries. Each frame combines 1,000 patterned sprites,
12 prepared authored-font labels, alpha blending, and two full-Canvas offscreen
compositions. Logical sizes are 320×180, 640×360 and 1280×720 with nearest
composition, plus 1280×720 with linear composition. The world/overlay sources
remain 320×180 and 160×90; entity count does not grow with resolution.

The final experiment ran three rounds per case/platform, with 120 discarded
warm-up frames and 240 measured frames each: 5,760 measured frames total.
Native and browser runs were sequential, using retained binaries built before
measurement. Native warm-up let the window settle, and every retained native
frame was checked for the final swapchain blit. Earlier exploratory runs under
other projects' build load, or without swapchain evidence, were excluded.
No Peas builds or tests ran concurrently with the final timed experiment.

Host: Intel i5-8279U at 2.40 GHz, 8 logical CPUs, 8 GiB RAM, Intel Iris Plus
655, macOS 15.7.7/Darwin 24.6.0, AC power/charging. Native used Cocoa/SDL GPU/
Metal. Chromium 157.0.8103.38 used ANGLE Metal on that same Intel GPU, with
WebGL 2.0 and a visible headless-browser page. Both observed 2560×1440 backing
framebuffers for 1280×720-point output. Zig 0.15.2 built native and baseline
wasm32-freestanding in ReleaseFast; Node was 24.19.0.

The [machine-readable report](../../benchmarks/game-rendering/2026-11-07-macos-x86_64.json)
retains per-run minimum/median/p95/p99/maximum/mean, parameters, hardware,
renderer, source/binary hashes, and memory evidence. Its companion
[compressed raw samples](../../benchmarks/game-rendering/2026-11-07-macos-x86_64.samples.json.gz)
include warm-up, permit recomputing the nearest-rank distributions, and are
identified by SHA-256 in the report. Screenshots, native/browser RGBA frames,
and full logs remain under `zig-out/diagnostics/render-capacity-final/`.

## Results

Values below are ranges across the three individual rounds, in milliseconds.
They are not pooled percentiles or an average of percentiles.

| Host / logical Canvas / composition | Draw median | Draw p95 | Host frame median | Loop/RAF interval median |
| --- | --- | --- | --- | --- |
| Native 320×180 nearest | 1.742–2.531 | 2.734–3.503 | 16.638–16.652 | 16.640–16.654 |
| Native 640×360 nearest | 3.100–3.429 | 4.416–5.345 | 16.650–16.675 | 16.654–16.679 |
| Native 1280×720 nearest | 6.339–6.895 | 7.789–9.098 | 16.647–16.667 | 16.647–16.667 |
| Native 1280×720 linear | 18.465–20.087 | 20.339–27.166 | 19.338–20.833 | 19.348–20.892 |
| Chromium 320×180 nearest | 1.9–3.0 | 3.5–4.4 | 2.2–3.4 | 16.6–16.7 |
| Chromium 640×360 nearest | 3.5–5.2 | 4.8–7.2 | 4.1–5.7 | 16.7 |
| Chromium 1280×720 nearest | 7.6–7.9 | 8.8–9.3 | 10.6–10.8 | 16.7 |
| Chromium 1280×720 linear | 112.7–116.2 | 114.7–146.6 | 115.6–119.2 | 116.1–119.8 |

Native host frame durations include swapchain pacing/driver waits. Browser
host frame durations are CPU callback time, which can return well before
the next RAF. Neither is a completed-GPU measurement or proof of actual
display scanout. In particular, native's approximately 16.7 ms nearest frames
do not imply that drawing itself used 16.7 ms.

| Case | Native composition median | Browser composition median | Browser upload-call median |
| --- | --- | --- | --- |
| 320×180 nearest | 0.465–0.569 | 0.5–0.8 | 0.1–0.2 |
| 640×360 nearest | 1.800–1.985 | 2.1–3.1 | 0.3–0.4 |
| 1280×720 nearest | 4.828–5.256 | 6.0–6.2 | 2.6–2.7 |
| 1280×720 linear | 17.105–18.720 | 111.1–114.6 | 2.5–2.7 |

Native sprite/clear/overlay work had per-round medians 1.073–1.653 ms, and
prepared text 0.177–0.306 ms. Browser corresponding medians were 1.1–1.9 ms
and 0.2–0.4 ms. Native light simulation medians were about 0.001–0.002 ms;
browser update measurements often rounded to zero at its observed 0.1 ms
clock resolution. This does not establish free simulation.

Native upload/presentation remained combined: medians were 13.955–14.839 ms
at 320×180, 13.086–13.374 ms at 640×360, 9.398–9.975 ms at 1280×720 nearest,
and 0.455–0.497 ms at 1280×720 linear. These values include pacing waits;
the small final value means less waiting after expensive CPU work, not a
faster GPU workload. Browser presentation-call medians were about 0.1 ms,
which measures submission, not completion.

All 8,640 recorded warm-up/measured game samples reported zero allocator
events and zero allocated bytes during update/draw. Wasm linear memory stayed
at its warm-up size: 6,029,312 bytes at 320×180, 6,815,744 at 640×360, and
9,961,472 at 1280×720. SDL, driver,
JavaScript and GPU allocation events remain unmeasured.

Each of the twelve browser runs produced a full logical frame identical to
the native CPU reference at deterministic tick 37, including authored text
and linear composition. Runtime/render status and console checks passed.
GPU readbacks, PNG capture and comparison happened after timing.

## Practical decision

Low-resolution Canvas presentation with nearest scaling remains a sensible
default for small pixel-art games. This particular 1,000-sprite workload left
substantial CPU submission headroom at 320×180 and 640×360 on this host. A
1280×720 nearest Canvas also completed its measured browser callbacks well
inside 16.7 ms in these runs, with less room for additional gameplay/effects.
These observations are workload-specific, not frame-rate guarantees.

Two full-resolution linearly composed CPU layers exceeded a 16.7 ms draw
budget even natively and were much more expensive in baseline Wasm. CPU
composition dominates that case; prepared text and sprite drawing do not.
Keep full-Canvas linear passes bounded, lower the logical resolution, use
nearest where appropriate, or measure a smaller composited area.

**The evidence now justifies a focused GPU surface-composition prototype.**
It does not justify replacing every ordinary Canvas operation or promise that
a GPU implementation is faster before it is measured. The next implementation
goal should be: add opt-in GPU scaling/alpha composition for retained offscreen
layers in ordinary GameProtocol games, keep CPU Canvas as the deterministic
reference, and rerun this same workload with output/ordering checks. Upload
cost, authored-text ordering and portable blend/rounding semantics must be
part of that experiment. General GPU sprite drawing is a broader decision.

## Audit follow-up and limits

Since the original audit, repository evidence covers repaired generated
projects and immutable archive consumers, physical-key/rebinding/committed-text
APIs, owned authored assets, prepared proportional text, explicit audio
release, and real Chromium/Firefox/Safari authoring workflows. Their guides
retain the validation and limitations; this experiment does not reclassify
injected composition events as physical IME tests or change preview status.
The missing complete ordinary-game rendering measurement is now resolved.

Remaining evidence gaps include Apple Silicon, interactive bare-metal Linux
and Windows, physical controllers/IME/speakers, and performance on other
hardware/browsers. The experiment has light simulation and fixed assets, no
collision-heavy game, no AI/networking, no custom-shader workload, no GPU
timer queries and no physical presentation timing. Native GPU readback was
not compared here; pixel equality uses native CPU and actual Wasm/WebGL output.

This was a normal shared workstation, without CPU affinity, temperature,
frequency or thermal isolation. Other projects' heavy build/test runs were
allowed to subside before the final experiment; routine application/OS load
and thermal drift remain possible, and the three-round ranges expose some
variation. No peer framework was measured. No GPU alternative or cause of the
native/Wasm linear-performance gap was measured. Shader conveniences and
larger-game services still need use-case evidence, rather than automatic
subsystem expansion.

## Commands verified for this experiment

```sh
zig build build-render-capacity -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
zig build test-render-capacity -Doptimize=ReleaseFast -Dbrowser-optimize=ReleaseFast -j2 --summary all
node script/benchmark_game_rendering.mjs --output zig-out/diagnostics/render-capacity-final
```

The full experiment passed 24 runs; the bounded native/Chromium correctness
command passed eight cases. Existing deterministic/API/golden validation is
retained separately from these hardware observations.
