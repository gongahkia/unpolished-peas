# Local logging and diagnostics follow-up — November 10, 2026

Peas now connects its existing structured event helpers to native and browser
hosts, bounds retained evidence and offers one
[debugging/support-export workflow](../guides/developer-diagnostics.md).
This closes a local debugging gap in the authoring audit. It does not establish
new hardware coverage, promote browser support or announce a release.

## Findings and implementation

The reviewed pre-change source at `659e8c57` confirms the gaps: native
`DeveloperTools` opened `unpolished-peas.log` without truncation and sought to
its end; automatic capture called `diagnostics.capture` on the same root each
time; browser artifacts appended to unrestricted arrays. Existing runtime-log
serialization/filtering and session-capture helpers were available but not
integrated into ordinary hosts. The debugging guides described separate tools
without a complete JSON CLI/support-export path.

| Requirement | Implementation and evidence |
| --- | --- |
| Consistent host events | Native readable/JSONL sinks and browser console/JSONL use the existing v1 event model, levels/categories and documented filters. Compiled lifecycle failures retain original errors and correlation. |
| Bounded retention | Native whole-record rotation and lifetime locks; ownership-marked incident retention; bounded browser messages/events/traces/commands/PNG/incidents. Unit tests verify eviction, truncation, rejected payloads, legacy oversized files and protected caller artifacts. |
| Actionable failures | Error, phase, callback/operation, session/frame and recent context; available environment, PNG, commands and traces. Early video failure is captured without a Canvas. Init/cleanup omit potentially expired borrowed commands. |
| Failure safety | Exhaustive ring/capture/export allocation failures, native sink allocation failures, blocked output and throwing browser sinks. Original failures survive diagnostic I/O/capture failure. Exclusive directory creation prevents cleanup of caller-owned output. |
| Agent workflow | Actual paths on stderr or artifact records; parseable JSON CLI stdout; real support exports, selection/redaction, rollback and a bounded manifest. |
| Compatibility and cost | Existing game APIs, strict snapshots, replay formats and goldens retained. New event/counter artifacts are additive. Disabled event collection returns before copies/serialization/clocks; enabled-mode ownership and costs are documented. |
| Discoverability | Existing guides/index and regenerated API boundary reference link one workflow for generated projects, checkout investigations, browser exports and headless regressions. |

Native logs use 1 MiB per file, three archives for each of the readable and
JSONL sinks (8 MiB combined), plus zero-byte lock files. Automatic retention
keeps the newest 32 owned incidents, at most 64 MiB each. Recent capture context
is at most 128 events/256 KiB. Incident recency uses filesystem modification
time, not randomly generated session IDs; the just-created incident is retained
even on timestamp ties. Unrecognized/caller-owned content is never pruned.

Browser defaults retain 128 diagnostic messages, 512 trace records and 256
commands; messages have a 1,024-byte UTF-8 cap and trace/command snapshots a
4,096-byte serialized cap. Structured events retain at most 128 records/256 KiB;
strings have a 1,024-byte cap and events at most 16 fields. Renderer metadata is
bounded to 4,096 serialized bytes; a PNG data URL to 16 MiB encoded ASCII. Four
incidents retain their own bounded context and applicable captures. Counters
report drops/rejections/truncation/sink errors. Support exports accept up to
four browser incident files and 64 MiB total, including their manifest.

Event timestamps are elapsed nanoseconds from host session start, capped at
2^53−1 for JavaScript-safe integers; browser clock resolution is browser-defined.
Session IDs are identities, not timestamps. Frame IDs are host presentation/RAF
iterations, not simulation ticks. These values stay outside saves and replay
input. Diagnostic replay JSON explicitly says `kind: diagnostic-summary` and
`complete_replay: false`; it is not a replacement for a complete UPR recording.

## Observed local workflows

Environment: Intel x86_64 macOS 15.7.7, Zig 0.15.2, Node 24.19.0 and Python
3.14.7. Native compiled probes use Cocoa → SDL GPU/Metal with dummy audio.
No rendering benchmark or physical speaker-quality measurement was performed.

| Workflow | Result |
| --- | --- |
| Compiled native consumer | Nine cases: init failure/repeat, blocked output, explicitly disabled tools, early SDL video failure, update failure, draw failure/filter and cleanup failure. Original errors, phases/operations, safe correlated JSONL, applicable PNGs and real JSON support exports verified. |
| Chromium 157.0.8103.38, WebGL 2 | External archive consumer, compiled authored-font layout and audio-lifetime cases passed; all three support exports passed. |
| Firefox 158.0, WebGL 2 | Same three cases and support exports passed. |
| Real Safari 18.6, WebGL 2 | Same three cases and support exports passed, with independent WebGL/PNG probe and Peas readback checks retained. PNG export was available on this run. |
| JSON CLI documentation commands | Fresh external project generation, `check` and macOS `doctor` returned parseable stdout with `status: ok`; human details stayed on stderr. |
| Untouched generated project | Local-checkout dependency, external directory with spaces and isolated empty caches: `zig build`, `zig build test`, `zig build web` and `zig build package` passed; generated source hashes remained unchanged. |

Each browser consumer retained 11 events and the latest four distinct incidents,
with three older incidents counted as dropped. Font/audio cases each retained
four events. Every browser case reported zero console-sink errors. Six
additional compiled init failures exercise retention after the existing
partial-init failure; resources and scheduled callbacks remain released.
Font readbacks retain the established native-reference comparison/tolerance.
Trusted input, actual save/reload, audio activation and repeated shutdown checks
are still required. Injected composition events remain explicitly distinct from
physical operating-system IME validation.

Validation exposed two automation/logging issues. Console instrumentation could
throw while stringifying a null-prototype fields object; host console output
now formats primitive fields into its readable string, and a zero-sink-error
assertion prevents a nominally passing run from hiding that loss. Safari could
receive trusted keys while its automation window was in the background. The
adapter now switches to the actual WebDriver window and waits for document
focus before input. It does not inject focus/key events. The full nine-case
matrix passed after these fixes; assertions/tolerances were retained.

A later repeat during optimized compilation hit a Firefox launch deadline
(20 seconds, before Peas loaded) and a Safari transport deadline (30 seconds,
before audio activation). Those cases were recorded as failures, not passed.
Their complete run is retained at
`zig-out/diagnostics/browser-authoring/failed-logging-run-a1eb581a13d445f186d3b9449c70b181/`.
Concurrent compilation was present; this does not prove it caused the timeouts.
WebDriver transport errors now retain method/path, deadline and original cause,
with a focused regression check. Deadlines remain unchanged. A subsequent matrix
was run separately after the optimized build completed.

That separate repeat also identified lost document focus between F4 opening the
textarea and injected composition. The retained state had a textarea active,
`document.hasFocus() == false`, host focus false and no JavaScript errors:
`zig-out/diagnostics/browser-authoring/failed-focus-run-f8ba6eef78254daeb49a97c065dda773/`.
Real window activation now covers injected input actions too, with a regression
check; observation calls still report actual focus without changing it.
Composition remains synthetic and never substitutes for physical IME evidence.
After this extension, the final combined command passed all nine cases and all
nine support exports with zero console-sink errors. The standalone Safari
consumer/font/audio subset also passed. Neither failed attempt was relabeled
as passed or discarded.

Evidence:

- `zig-out/diagnostics/local-logging/native/run-<id>/result.json` and per-case
  stdout/stderr, copied local logs, incidents and support manifests. App-data
  cleanup only touches the fixture's unique UUID namespace.
- `zig-out/diagnostics/browser-authoring/consumer/result.json` and
  `browser/result.json`; each browser/case report points to
  `runtime-artifacts/<session>/` and `support/<session>/`. Existing probes,
  screenshots/readbacks, harness hashes, console and environment evidence remain.
- `zig-out/diagnostics/local-logging/cli/` retains JSON stdout and separate
  stderr for the documented generation/check/doctor commands.
- `zig-out/diagnostics/local-logging/validation/run-84e0b90703c0443085b2ff26902e43fb/`
  retains successful validation logs and an evidence manifest linking the final
  browser report and native run. Native source hashes match the final worktree.

## Validation commands

Run from the engine checkout; browser prerequisites are in the
[authoring guide](../guides/browser-authoring.md). Run desktop and browser input
workflows serially to avoid focus interference.

```sh
zig test src/runtime_log.zig
zig test src/support_bundle.zig
node script/test_browser_artifacts.mjs
node script/test_browser_host.mjs
node script/browser-authoring/contract.mjs
script/test_support_bundle_cli.sh
zig build test-browser-authoring -Dauthoring-logging=true -Dwith_sdl=false -j2 --summary all
zig build test-runtime-logging test-sdl -j2 --summary all
zig build test-sdl check-examples -Doptimize=ReleaseFast -j2 --summary all
zig build test-starter-external -Dwith_sdl=false -j2 --summary all
zig build test test-core-api test-support test-replays test-scenes test-docs docs \
  test-browser-runtime test-browser-wasm-host test-browser-protocol-host \
  test-browser-host test-browser-webgpu test-browser-artifacts test-browser-contract \
  test-browser-authoring-contract test-peas test-starter test-dogfood test-lantern-leap \
  -Dwith_sdl=false -j2 --summary all
zig build docs-update-api -Dwith_sdl=false -j2 --summary all
zig build test-docs docs -Dwith_sdl=false -j2 --summary all
zig build test-docs docs test-browser-authoring-contract test-safari-webdriver-contract \
  -Dwith_sdl=false -j2 --summary all
actionlint .github/workflows/nightly.yml
zig fmt --check build.zig src/backend/sdl_gpu.zig src/runtime_log.zig src/support_bundle.zig
git diff --check
```

The nightly `portable-authoring` job enables logging assertions on its existing
three-browser matrix and runs the native workflow separately with a six-minute
step bound. Artifact upload includes local-logging evidence even on failure.
CI wiring was linted locally; no remote workflow execution is claimed.

The broad suite passed **133/133 steps and 652/652 tests**. Native workflow/SDL
validation passed **9/9 steps**, all nine compiled failure cases and **72/72 SDL
tests**. Final documentation/authoring/Safari transport checks passed **47/47 steps and
36/36 tests**. Standalone runtime-log and support-export suites passed **9/9**
and **5/5** tests, including exhaustive allocation rollback. The external
generated-project check passed **2/2 steps**. Font/API/asset/input/audio/replay
native/Wasm comparisons and existing strict API/golden assertions remained
enabled.
The optimized `test-sdl check-examples` command passed **51/51 steps and 72/72
tests**, compiling every example in ReleaseFast.

## Remaining limitations

- Browser evidence is in memory until explicitly exported; reload/new host
  creation loses it. Host payload caps do not bound total JS heap, browser
  console, PNG temporary buffers or driver memory.
- Safari input automation needs a foreground automation window. The adapter
  restores real focus before input actions; unrelated desktop activity can
  still interrupt a run. Observations and failures are retained without
  suppressing focus assertions.
- Native enabled logging/capture allocates and writes synchronously. Optimized
  builds retain failure-only capture by default; `UP_DEVELOPER_TOOLS=0` suppresses
  it. Logging filters do not suppress the original human failure report.
- Native environment metadata reports engine version/build revision as
  `unreported`; record the checkout commit separately. Existing callback-error
  display can eventually exit zero, while cleanup errors retain the existing
  panic policy. Consumers must inspect incidents and test assertions.
- Redaction performs configured textual substitutions and leaves pixels intact.
  Inspect exports before sharing. Very large browser evidence can require
  selecting fewer artifacts to meet the 64 MiB export limit.
- Apple Silicon, bare-metal Linux/Windows interaction, physical controllers,
  operating-system IME and speaker quality remain outside this local evidence.
  Browser preview status, README files, license and release state are unchanged.
