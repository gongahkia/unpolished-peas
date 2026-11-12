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

## Save attribution follow-up — 2026-11-12

**Conclusion: the historical 40.598 ms update spike was not reproduced; its cause
remains unproven. No persistence or gameplay fix is justified by this sample.**
Current observations confirm a real write at tick 555, accounting for most of its
0.6–1.3 ms update. This cannot retroactively attribute the historical 40.6 ms
update. A warm-up save took 14.73 ms. No extra targeted experiment was used after
the initial comparison; the investigation stops at this bounded finding.

Started from clean HEAD d6441b09, preserving the completed shared replay adapter.
Historical `ashen-profile-polish` JSON/logs/CPU samples remain unchanged; their
SHA256 values are in the new report. Measured source tree:
`5dce64208f850ffabc3abcd0f3682bad92c9718f` (worktree over d6441b09).
Exact source/binary hashes, command, power/display state and toolchain are in
root `zig-out/diagnostics/ashen-save-attribution-20261112/result.json`.
All three measured executables are retained under its `measured-binaries` child.
Hardware remains Intel i5-8279U/Iris Plus 655, macOS 15.7.7, Zig 0.15.2,
ReleaseFast, Canvas 480×270 and framebuffer 1920×1080.

### Method and reproduction

The optional verification host borrows a SaveStore wrapper during instrumented
updates, timing actual parent operations and recording kind, byte count, replay
tick, monotonic start/end and success/error. Preparation still performs real
saves outside the measured window. Both modes use the same optimized binary;
baseline uses the original store directly. Shipping main/web never imports the
helpers. Observations stay outside Game, save bytes and replay input.

Before the loop, instrumented mode allocates and touches storage for 2,048
update records and 256 operations. Observer callbacks perform no allocation,
logging, screenshots or readbacks.
Overflow is reported and rejected. JSON, final saved-byte read/decode and state
comparison occur after the loop. Actual parent allocation/file creation/write/
sync/close/rename remains unchanged. The collector's tick intervals are
partitioned by the existing host sample's `update_calls`, handling zero/catch-up
updates without comparing clock origins. End-state digests and persisted bytes
must equal the CPU replay at each run's actual end tick; all twelve runs pass.
Three full CPU routes also match per-tick state/save oracles, retaining 31 update
requests/2,530 bytes, zero draw/mix allocations and zero tracked live bytes after
cleanup.

Use a new UUID/output directory for another investigation; existing reports are
never overwritten. Exact commands used, with builds finished before measurement
and all CPU/native workloads serial:

```sh
cd dogfood/ashen-causeway
zig build test test-profile-observer build-profiling -Doptimize=ReleaseFast -Dverification-id=profile-70e3a6dd-7dd8-4c59-9b9c-bb1ffef94072 -j2 --summary all
cd ../..
python3 script/test_profile_ashen_causeway.py
python3 script/profile_ashen_causeway.py --identity profile-70e3a6dd-7dd8-4c59-9b9c-bb1ffef94072 --rounds 3 --compare-saves --output zig-out/diagnostics/ashen-save-attribution-20261112
```

The existing replay SHA256 is
`eb104378fcd4242c63fda4503e3b8395172e1b4e9bae2a27a6c3114ca580a227`;
no artifact needed regeneration. A fresh checkout first uses GUIDE's
`ASHEN_ROUTE_EVIDENCE=zig-out/evidence/routes zig build test`.

Three baseline and three instrumented runs per ordinary/boss case each record
360 frames, discard 120 warm-up frames from the main distributions and retain
240. Cases/modes reverse order in round two. Every retained frame has both
expected render passes; no samples drop and no observer progress logs occur.
Twelve retained frames contain multiple updates and are associated without loss.
The guarded UUID namespace was removed after every run and is absent afterwards;
production saves and prior reports are preserved.

### Measurements

Pooled nearest-rank distributions, 720 retained frames per row, milliseconds.
Pooling describes these runs, not independence or a confidence interval.
Per-round distributions and all correlated frames remain in the report.

| Case / mode | Update median / p95 / max | Frame median / p95 / max | Frames >20 / >33.333 / >41.210 ms |
| --- | --- | --- | --- |
| Ordinary baseline | 0.0193 / 0.0493 / 1.3707 | 16.667 / 17.513 / 33.689 | 7 / 1 / 0 |
| Ordinary instrumented | 0.0219 / 0.0441 / 1.3130 | 16.664 / 17.782 / 36.431 | 4 / 2 / 0 |
| Boss/shock baseline | 0.0194 / 0.0357 / 0.1186 | 16.654 / 18.021 / 33.146 | 3 / 0 / 0 |
| Boss/shock instrumented | 0.0214 / 0.0438 / 0.1066 | 16.654 / 17.665 / 23.961 | 9 / 0 / 0 |

No retained update exceeds 5 ms (0/2,880); no retained frame exceeds the historical
41.210248 ms (0/2,880). Eleven of the 1,440 warm-up frames do exceed that frame
duration. Warm-up maxima in table order are 47.272, 98.543, 86.424 and 72.326 ms;
their maximum-frame updates are only 0.022–0.071 ms. Much of those durations lies
outside the three measured stage boundaries and remains unattributed. Raw warm-up
records are retained; excluding them does not imply a frame-time guarantee.

All six measured store operations are successful 40-byte writes: two per
instrumented ordinary run, none in the measured boss windows. Tick 363 is in
warm-up, tick 555 is retained:

| Round | Tick 363 write (ms) | Tick 555 write (ms) | Tick 555 update (ms) | Tick 555 residual (ms) |
| --- | --- | --- | --- | --- |
| 1 | 0.886840 | 0.988771 | 1.012904 | 0.024133 |
| 2 | 14.726347 | 1.291024 | 1.312961 | 0.021937 |
| 3 | 1.451170 | 0.580526 | 0.594396 | 0.013870 |

All-write median is 0.988771 ms, p95/max 14.726347 ms; six observations cannot
establish a tail distribution. Instrumented ordinary residual update
median/p95/max is 0.021938/0.043044/0.113178 ms. Residual is aggregate host update
wall time minus nested store-call wall time; it includes other game/host work,
observer recording and scheduling outside calls. Baseline has no measured store
time, so its reported residual equals total update.

The warm-up 14.743034 ms update contains the 14.726347 ms write, leaving
0.016687 ms residual. The largest retained frame, 36.430782 ms at tick 555 in
round three, contains just 0.594396 ms update, 0.580526 ms write and 35.615245 ms
upload/present. It is not an update-dominated recurrence of the historical sample.
Upload/present includes driver/swapchain waits, not GPU execution time.

Controlled observer cost uses a no-op parent, not disk: 40 alternating batches
of 200 update/write pairs, discarding four batches. Median cost per pair is
0.002025 µs baseline and 0.151485 µs instrumented (difference 0.149460 µs;
instrumented p95 0.249935 µs). This measures wrapper, four clocks and bounded
recording together. Real native paired update-median differences range from
−5.765 to +15.932 µs; variation exceeds controlled overhead, so this proves
neither zero cost nor a stable native slowdown. All batches remain in
`observer-overhead.json`. No machine-specific timing gate was added to CI.

### Checks, confidence and next measurement

Optimized game/observer/build checks pass 18 steps/66 tests (34 game, 32 observer
and imported game tests). Python association tests pass three cases, including
zero/multiple updates and rejection of incomplete/misattributed/failed records.
Collector tests use controlled clocks/stores for association, both overflows,
disabled clocks, storage errors/failed-write preservation and byte-identical
replay. Ordinary Debug test/observer/web/package passes 23 steps/66 tests.
Additional exact check from the engine root:

```sh
zig build test-storage test-core-api test-public-import-inventory -Dwith_sdl=false -j2 --summary all
```

It passes 10 steps/9 tests, including native atomic replacement/failure/retry.
Logs: root `zig-out/diagnostics/ashen-save-{observer-build-final,normal-checks,engine-checks}.log`.
An initial name-shadowing compile failure is retained in
`ashen-save-observer-build.log`; it produced no measurements.

Final review additionally made post-loop report errors release game/observer
resources before propagating, and writes available operation records before
rejecting mismatched save bytes. A deterministic missing-save test exercises that
cleanup without native timing. These changes are confined to untimed reporting;
the matrix above describes the retained measured source/binaries, before that
error-path hardening. No further performance experiment was run.

Final hardening build/check, from the game directory:

```sh
zig build test-profile-observer build-profiling -Doptimize=ReleaseFast -Dverification-id=profile-70e3a6dd-7dd8-4c59-9b9c-bb1ffef94072 -j2 --summary all
```

Passes 15 steps/33 tests; missing and short saved blobs fail reporting while
still releasing resources, and short reports contain only initialized saved
bytes. Log: root `zig-out/diagnostics/ashen-save-observer-final-checked.log`.
The earlier cleanup-test compile used AudioMixer instead of the GameContext
Audio service; that failed build is retained in `ashen-save-observer-final.log`
and produced no measurement. Final storage/API/inventory checks pass again in
`ashen-save-engine-final.log`. Docs plus the existing shared replay-driver test
pass 42 steps/36 tests (`ashen-save-docs-checks.log`). Ordinary web Wasm retains
SHA256 `6bfa7dc86962f2dbe0b2026f0eddc6bd40c2170942cf69302f9978f105191790`.
The final docs-only rerun, `zig build test-docs -Dwith_sdl=false -j2 --summary all`,
passes 40 steps/36 tests (`ashen-save-docs-final.log`).

Confidence is high in association and the observed time within the parent write
boundary. That interval includes possible descheduling while the call is active;
it does not identify file.sync, another syscall or the storage device as the
cause. The original update tail remains unattributed. No sync, save, atomic
replacement, failure propagation, format or durability behavior changed; no
asynchronous/deferred persistence or engine optimization was introduced.

If this becomes a recurring play issue, the next measurement is a fresh bounded
capture with the same association plus a platform scheduler/file-I/O trace, and
optional sub-operation timestamps around temporary creation, write, sync, close
and rename. This is a proposed follow-up, not an experiment performed here. A
persistence-policy change requires an explicit durability/feedback tradeoff.
These observations support no universal frame-rate or cross-hardware claim.
