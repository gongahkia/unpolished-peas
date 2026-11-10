# RPG workload observations — 2026-11-10

Measured production game sources at 471a17dd with optional profiling helpers in
the worktree. Actual source/binary SHA256 values, machine context, full samples
and commands are retained in root `zig-out/diagnostics/ashen-profile/result.json`,
`cpu-*.json.gz` and `native-*.log`. No performance budget or universal frame-rate
claim is implied.

Intel Core i5-8279U at 2.40 GHz, Iris Plus 655, macOS 15.7.7, Zig 0.15.2,
ReleaseFast. Logical Canvas 480×270; real SDL framebuffer 1920×1080. Builds finished
before measurement; CPU runs and SDL windows ran serially. The ordinary Canvas
path was retained. Reproduce from the game directory, after generating the route
as in GUIDE:

```
zig build build-profiling -Doptimize=ReleaseFast -Dverification-id=profile-f40360be-476b-4ed8-afc3-a950a77c06ac -j2
cd ../..
python3 script/profile_ashen_causeway.py --identity profile-f40360be-476b-4ed8-afc3-a950a77c06ac
```

Use a fresh `profile-UUID` for a new investigation, with the same value in both
commands. The helper checks the actual application namespace and removes only
that namespace after the native host proves it started empty. It leaves production
saves alone. The recorded namespace was confirmed absent after all six windows.

Three CPU runs each replay all 6,577 ordinary input ticks, draw every tick and mix
800 stereo frames/tick at 48 kHz. Public HeadlessGameRunner supplies capabilities;
its structural Canvas observer is detached for timing. A counting allocator follows
the existing render benchmark pattern, additionally tracking live/peak requested
bytes. Counts include game resources, logical audio, in-memory saves and headless
host objects. Replay/sample/report storage is outside that allocator. First 120
samples are omitted from timing summaries, but included in allocation totals.
Timers and observer overhead are retained. No file I/O or captures occur in timed
CPU samples. These compressed runs measure CPU work, not realtime scheduling.

| Workload | Samples/run | Update median / p95 (ms) | Draw median / p95 (ms) | Mix median / p95 (ms) |
| --- | ---: | --- | --- | --- |
| Quay/Cloister | 4,590 | 0.0064–0.0065 / 0.0088–0.0093 | 0.113–0.114 / 0.182–0.186 | 0.0047 / 0.0106–0.0108 |
| Active Warden shock | 60 | 0.0063–0.0065 / 0.0074–0.0102 | 0.244–0.258 / 0.313–0.332 | 0.0046 / 0.0049–0.0052 |

Ranges show the three runs' statistics, not a confidence interval. The ordinary
route reaches four living enemies and one shot; shock samples have one boss and
one ring. These are maxima observed along real content, not a synthetic fill of
the 32-enemy/32-shot/four-ring capacities. The shock is the more expensive visible
workload here, owing to its circular outlines. No measured bottleneck justified
changing the renderer or removing that telegraph.

Every run reports zero draw allocation events and zero mixing allocation events.
Updates report 31 allocation/growth events totaling 2,530 requested bytes after
initialization, spread over 27 input ticks; the exact ticks are in the report.
This includes portable storage and audio requests and is not evidence that all
game updates allocate nothing. The in-memory store copies replacement bytes and
the mixer retains playback capacity. Attribution has not been split into separate
service counters. Initialization makes 267 requests totaling 2,073,900 bytes;
peak live requested bytes are 1,922,822, ending live bytes 1,922,782, and full
runner cleanup returns the counter to zero on each run. These are requested Zig
bytes, not process RSS, C-library/driver memory or a claim about physical devices.

For SDL, the optional verification host reconstructs tick 300 or 5,950 with the
same replay before the timed loop, including logical audio mixing. It then uses
normal fixed updates and rendering. The existing UP_NATIVE_TIMING_SAMPLES reporter
records 360 presented frames, discarding 120 and retaining 240, in three rounds
with reversed case order on the second round. The phase-two window reaches the
shock at tick 6,293. No screenshot/readback or capture file writing occurs in timed native
frames. Ordinary game saves remain in update timing. The original ordinary runs
also emitted one observer progress line at tick 600; the final profiling helper
suppresses that line in profile mode, and the corrected rerun is recorded below. All retained frames contain both expected render passes; no samples drop.

| SDL window | Draw median / p95 (ms) | Upload/present median (ms) | Frame median / p95 (ms) |
| --- | --- | --- | --- |
| Ordinary | 0.209–0.237 / 0.349–0.420 | 16.206–16.274 | 16.649–16.670 / 17.062–17.074 |
| Phase two / shock | 0.303–0.369 / 0.633–0.642 | 16.055–16.165 | 16.664–16.677 / 17.064–17.127 |

Native draw includes host boundaries/Canvas clear; it is not identical to the
headless game-only draw boundary. Upload/present includes staging, command encoding,
swapchain/driver waits and pacing; it is not GPU execution time. The largest native
frame was 18.221 ms. One ordinary update aggregate reached 14.487 ms; the report
does not attribute that isolated outlier to a specific operation. Native resource
allocation counts, browser performance/JavaScript allocations, GPU completion,
scanout and physical input latency remain unmeasured. Diagnostic timestamps and
samples stay outside game state, saves and replay input.

A final one-round correctness rerun after tightening profile cleanup and setting
fixed-step context fields explicitly also passed, with the same allocation totals
and zero live bytes after cleanup. Evidence: root
`zig-out/diagnostics/ashen-profile-final/result.json`; invoke the runner above with
`--rounds 1 --output zig-out/diagnostics/ashen-profile-final`. Its native draw
medians were 0.287 ms ordinary and 0.365 ms phase two. This additional observation
is kept separate from the three-round distributions above rather than silently
replacing those retained measurements. Final Debug tests/web build passed all
15 steps and 31 tests; optional profiling tools built all 10 steps.

## Final presentation/resource rerun

After the reviewed poses, pause feedback, accurate title state, accepted-command
cues and test-copy catalog cleanup, rebuilt all profiling tools before measurement:

```
zig build build-profiling test package -Doptimize=ReleaseFast -Dverification-id=profile-e854d7cc-1e8f-4e73-a325-84f93f314c6b -j2 --summary all
cd ../..
python3 script/profile_ashen_causeway.py --identity profile-e854d7cc-1e8f-4e73-a325-84f93f314c6b --rounds 1 --output zig-out/diagnostics/ashen-profile-polish
```

The build passes 18 steps/34 tests. The one-round measurement passes a full CPU
route and both SDL windows, with 120 warm-up/240 retained frames, zero dropped or
unpresented samples, and no progress logging in profile mode. Its source/binary
hashes and raw samples remain in the named report directory. This is a separate
current-game observation, not a replacement for the historical three-round data.

Current initialization makes 243 allocation requests totaling 2,031,076 requested
bytes; peak live bytes are 1,879,998 and cleanup returns to zero. The smaller
prepared-copy catalog removes test names. Updates still make 31 requests totaling
2,530 bytes across the whole route; drawing/mixing still allocate zero times.
The actual source/host scope of these counters remains the one described above.

| Current case | Update median / p95 (ms) | Draw median / p95 (ms) |
| --- | --- | --- |
| CPU ordinary (4,590 samples) | 0.0063 / 0.0087 | 0.117 / 0.157 |
| CPU active shock (60 samples) | 0.0065 / 0.0227 | 0.276 / 0.354 |
| SDL ordinary (240 samples) | 0.0165 / 0.0272 | 0.166 / 0.228 |
| SDL phase two/shock (240 samples) | 0.0254 / 0.0471 | 0.317 / 0.666 |

SDL frame medians are 16.665/16.646 ms, with p95 of 16.836/17.179 ms. The ordinary
window has one 40.598 ms update and 41.210 ms complete frame at replay input tick 555.
The corresponding headless tick has one 40-byte update allocation. Game.persist
uses synchronous SaveStore.write, including native temporary-file sync/rename,
so storage work is a candidate; no per-write timer or OS scheduler attribution
was collected. The outlier is retained and is **not** a demonstrated renderer
bottleneck or proof of its cause. Ordinary game saves remain part of update cost.
The other native window's largest frame is 17.921 ms. These tails rule out any
hard frame-time guarantee from the medians.

The profile wrapper now suppresses its periodic progress line (the earlier runs
included that observer I/O), rejects failed game persistence, and the runner
asserts no progress lines occurred. Only the corrected final run has that complete
observation contract. The exact profile UUID directory was confirmed removed.
