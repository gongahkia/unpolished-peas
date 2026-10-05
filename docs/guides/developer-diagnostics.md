# Developer diagnostics

Peas has a small, local developer diagnostics view for native SDL runs. It is
for answering what a game is doing during development, not for collecting
telemetry or replacing the benchmark suite.

## Enable

The SDL host enables developer tools by default in a Zig `Debug` build. Enable
them explicitly in an optimized investigation build without changing game
source:

```sh
UP_DEVELOPER_TOOLS=1 zig build -Doptimize=ReleaseFast run-dogfood
```

Set `UP_DEVELOPER_TOOLS=0` to suppress the host developer tools for a session.
The existing native `Config.developer_tools` setting remains the source-level
alternative for hosts that configure it directly.

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
