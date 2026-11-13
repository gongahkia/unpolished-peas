# Developer diagnostics

Use this workflow to reproduce a failure, inspect its local evidence and export
a support bundle. Native logs, browser artifacts and headless tests serve
different purposes. None uploads telemetry or changes game saves/replay input.

## Enable

The SDL host enables developer tools by default in a Zig `Debug` build. Enable
them explicitly in an optimized investigation build without changing game
source:

```sh
UP_DEVELOPER_TOOLS=1 zig build -Doptimize=ReleaseFast run-dogfood
```

From an **already generated game directory**, reproduce a bounded native run:

```sh
UP_DEVELOPER_TOOLS=1 UP_DEVELOPER_OVERLAY=0 \
  UP_DEVELOPER_DIAGNOSTICS_DUMP=1 zig build run -- --frames 120
```

From the **engine checkout**, use the same environment with `run-starter` or
`run-dogfood`. Start with the ordinary Debug build; optimized builds keep
continuous logging/overlays off by default, while retaining failure-only
captures. Set `UP_DEVELOPER_TOOLS=0` to suppress automatic captures as well as
the developer tools for a session. `UP_LOG_LEVEL=off` disables structured/file
logging while keeping otherwise enabled overlays and failure captures.
The existing native `Config.developer_tools` setting remains the source-level
alternative for hosts that configure it directly.

Filter enabled native logs without changing game code:

```sh
UP_DEVELOPER_TOOLS=1 UP_DEVELOPER_OVERLAY=0 \
  UP_LOG_LEVEL=warn UP_LOG_CATEGORIES=engine,render,assets,diagnostics \
  zig build run -- --frames 120
```

Levels are `trace`, `debug`, `info`, `warn`, `err`, `fatal`, or `off`; the default
minimum is `info`. Categories are `engine`, `assets`, `render`, `input`, `audio`,
`storage`, `diagnostics`, `platform`, or `all`. Categories use a comma-separated
list without spaces. Invalid filters warn and disable logging for that run;
they do not replace a game error. Logs describe lifecycle and noteworthy events,
not every frame. Existing human failure messages still reach stderr.

The compact overlay starts enabled. Set `UP_DEVELOPER_OVERLAY=0` to start it
hidden, and set `UP_DEVELOPER_INSPECTOR=1` to start the detailed inspector.
There are deliberately **no default developer keyboard shortcuts**: a game
keeps `Tab`, `F3`, `F12`, and every other normalized key binding even when
developer tools are enabled. This prevents host tooling from changing a
game's input semantics.

For a one-shot local JSON snapshot written when the native host exits:

```sh
UP_DEVELOPER_TOOLS=1 UP_DEVELOPER_DIAGNOSTICS_DUMP=1 zig build run-dogfood
```

The file is named `developer-diagnostics.json` in the application-data
directory that Peas prints when developer tools start. It is never uploaded or
reported over the network.

Starting the overlay hidden keeps collection enabled and is useful when
comparing its visual cost with collection alone.

## Find and inspect native evidence

The SDL host prints the actual application-data, log and incident paths on
stderr. Use those paths: their location depends on the operating system and
game's organization/application names.

| Artifact | Contents and lifetime |
| --- | --- |
| `unpolished-peas.log` | Human-readable events; 1 MiB active file and three 1 MiB archives |
| `unpolished-peas.jsonl` | One structured event per line; same independent rotation budget |
| `diagnostics/session-<id>-failure-<n>/` | Distinct failure evidence; newest 32 owned incidents, at most 64 MiB each |
| `developer-diagnostics.json` | Optional last-completed-frame snapshot, replaced on a later requested dump |

`UP_DIAGNOSTICS_ROOT` overrides the incident root for local investigations and
tests. It does not relocate continuous logs. Rotation uses exact owned log
names; each sink keeps a zero-byte `.lock` file. A concurrent process that
cannot acquire a sink lock reports `LogBusy` and retains memory/incident logging
instead. Do not remove live lock files. Incident retention only removes marked
Peas directories containing recognized regular artifacts; caller files and
lookalike directories are left alone. Those protected directories are outside
the retention budget.
An active log file is created on its first accepted event; filters may leave it
absent. Failure-only captures can have empty `events.jsonl` when continuous
collection is off; the original failure remains in `failure.log`.

An incident contains `failure.log`, `metadata.json`, `environment.json`,
`events.jsonl`, `logging.json`, `commands.json`, and applicable `screenshot.png`
and `trace.json`. Inspect the original error, phase and operation first, then
look backward through recent events. `logging.json` reports dropped/truncated
records, write errors, file rotations and discarded bytes. Failure captures
retain at most 128 events/256 KiB, 256 commands, 256 bytes per command text and
16 KiB of failure text. Init/cleanup captures omit borrowed render commands
because their resources may already have expired; `commands_omitted` records
that choice. Early video failures have no screenshot.

Schema-v1 event records share `timestamp_ns`, `session_id`, `frame_id`, `level`,
`category`, `message`, and primitive `fields`. Host session IDs are positive
integers safe in JavaScript. Timestamps are elapsed nanoseconds since that
host session started, capped at 2^53−1; they are not UTC timestamps. Browser
clock resolution depends on the browser. Frames count host presentation/RAF
iterations, not deterministic simulation ticks. Text values are truncated at a
valid UTF-8 boundary to 1,024 bytes, with at most 16 fields per event. These
observations never enter game state.

Available native metadata includes target, Zig version, optimization mode,
selected renderer/video driver and configured asset root. Engine version/build
revision currently say `unreported`; record your own commit ID alongside an
export. Native callback failures can enter the existing error display and
eventually exit successfully after closing; inspect failure evidence rather
than treating exit code zero as proof that gameplay succeeded. Cleanup errors
retain the existing panic behavior after attempting capture.

## Check a project and export evidence

Run the CLI from the **engine checkout**, pointing it at the generated game:

```sh
zig build peas -- --json --non-interactive check ../my-game
zig build peas -- --json --non-interactive doctor ../my-game --target macos
zig build peas -- --json --non-interactive support-bundle \
  /actual/incident/directory /new/local/support-directory \
  --redact-path /private/project/path --redact example-secret
```

Select the actual target (`macos`, `linux`, `windows`, `web`) for `doctor`.
`check` and `doctor` inspect configuration/prerequisites; they do not prove a
game's runtime behavior. The CLI writes a JSON result to stdout, human context
and actual export paths to stderr, and retains its existing exit/recovery codes.
For an agent, capture both streams and check the exit code and JSON status.

The export directory must be new and outside the evidence source. Use repeated
`--include <filename>` to select artifacts; otherwise recognized artifacts are
copied. The local manifest `support-bundle.json` lists copied names and redaction
counts. Exports accept up to four browser `incident-<id>-<n>.json` files and
64 MiB total including the manifest. Redaction replaces the source directory
and requested literal/path strings in textual artifacts. It does not inspect
pixels or infer secrets; inspect screenshots and game-authored text before
sharing an export. Nothing is uploaded by this command.

## Browser and headless investigations

For a served generated game, open
`http://127.0.0.1:8000/?renderer=webgl2&peas-log=debug`.
Add `&peas-log-categories=engine,render,assets,diagnostics` when needed.
The browser console shows readable events; `window.unpolishedPeas.host.artifacts()`
returns bounded local artifacts, including JSONL, retention metadata and recent
incidents. Browser collection is off by default. Evidence remains in memory
until exported; reload/new host creation loses it. See
[browser diagnostics](browser-diagnostics.md#local-logs-and-failure-evidence)
for inspection and export without a repository-only runtime dependency.

Headless `zig build test` verifies game state, replay input and logical pixels
without SDL/browser logs or a physical display. Use the [testing guide](testing.md)
to turn a runtime observation into a deterministic regression. A diagnostic
`replay.json` is explicitly a `diagnostic-summary` with `complete_replay: false`;
it cannot replace a complete input replay recording.

From the engine checkout, the compiled workflow checks are:

```sh
zig build test-runtime-logging -j2 --summary all
zig build test-browser-authoring -Dauthoring-logging=true \
  -Dwith_sdl=false -j2 --summary all
```

The native check requires a working desktop SDL host; the browser check needs
the [browser prerequisites](browser-authoring.md#prerequisites-and-commands).
Run them serially so native windows cannot steal Safari's input focus. Native
evidence is retained under `zig-out/diagnostics/local-logging/native/run-<id>/`;
browser case reports point to their session-specific artifact and support-export
directories. Unavailable prerequisites are unverified, never passed.

## Ownership and enabled costs

Native recent events own their strings and fields. Enabled logging copies
events, reads a clock and formats/writes files synchronously; captures allocate
and perform filesystem/PNG work. It is developer tooling, not a real-time logging
service. Disabled logging returns before event copies, clock reads and writes;
existing failure-only capture may still run unless explicitly suppressed.

Browser logs own serialized records; traces/commands own bounded JSON snapshots.
Retention budgets cover payloads, not total JS object, console or graphics-driver
memory. Explicit snapshots, PNG capture and serialization can allocate temporary
buffers. Browser logging off avoids structured-event serialization/clock reads;
bounded protocol-failure messages and explicitly requested legacy captures
remain available. Enabled overlays/profiling have
their own costs, described below.

## Snapshot and overlay

The compact view displays the last completed presentation frame. It contains:

- presentation FPS, simulation tick, fixed updates in the completed frame,
  fixed Hz, and the explicit simulation seed when one was configured;
- rolling (up to 120 presentation frames) CPU means for fixed-update work,
  game draw work, and host presentation/submission work;
- logical window, framebuffer, Canvas sizes, and framebuffer scale;
- requested/selected renderer, SDL video driver, SDL GPU shader path, and
  fallback/recovery state (the compact overlay shows recovery; the local JSON
  contains both states);
- native render-command queue count, sprite draws and emitted sprite batches,
  material sprites, particle instances/batches, and post passes;
- audio and save-capability availability.

When a high-level music stream is active, the optional local JSON snapshot
also records its state, encoded-byte count, source/decoder frame positions,
bounded PCM-buffer occupancy, and decoder underrun count (currently zero in
the synchronous refill model). These are local
developer observations; host presentation timing and device queue depth are
not completed-GPU or speaker-clock measurements.

`CMD` is the native `RenderCommandBuffer` queue length, not a Canvas command
trace. The overlay does **not** attach a `CanvasTrace`, hash resources, or
record every Canvas operation.

## Timing semantics

`update` is CPU wall-clock time spent in all fixed game updates within one
presentation frame. `draw` is CPU wall-clock time for `Game.draw`. `host
present` is the host-side time spent submitting/presenting through the
renderer. It can include driver waits, but it is **not GPU completion time**;
Peas does not issue GPU timestamp queries here. `frame` is the wall-clock
presentation-frame duration used to derive displayed FPS.

Timings are developer-only and nondeterministic. They are not exposed to game
simulation and must not be used for gameplay decisions.

## Determinism and tests

With developer tools disabled, Peas does no extra diagnostics clock reads or
diagnostic-work aggregation. The developer Canvas output is drawn with any
attached test trace temporarily suspended, so it does not alter a game-owned
`CanvasTrace`. It naturally changes displayed pixels while enabled, but normal
headless replay, Canvas-trace, and pixel tests remain unchanged.

Headless tests can continue to use their deterministic game state and Canvas
facilities. The private diagnostics collector has focused unit coverage, but
ordinary correctness tests do not assert wall-clock timing.

## Browser and benchmarks

The bounded snapshot data model uses only Zig values and is browser-compatible,
but this compact host overlay is currently an SDL-native developer facility.
Browser renderer diagnostics remain host-specific. Use the rendering benchmark
targets to compare implementations; use this view to understand one running
game. WSLg timing can help diagnose a local WSLg session, but is not a
bare-metal Linux GPU benchmark.
