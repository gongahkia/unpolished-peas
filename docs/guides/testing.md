# Deterministic testing

Start with the complete compiled test in
[Seed Sprint](../../templates/starter/src/game.zig). It records normalized
fixed-tick input, initializes fresh headless games with seed `42`, asserts
game state, compares a Canvas trace, and hashes the representative final
logical draw. That is the normal Peas testing story—not a requirement to
build a custom test framework.

## Test layers

Use the smallest layer that catches the regression you care about:

1. **Simulation state** — a seed, controlled initial save data, and fixed-tick
   input produce the expected score, position, or game outcome.
2. **Logical Canvas commands** — the game requested the expected rendering
   operations, with useful field-level mismatch diagnostics.
3. **Pixels** — the deterministic CPU Canvas output changed as expected or
   unexpectedly.

The layers complement one another. Equal state does not prove equal drawing;
equal Canvas commands do not prove a renderer/pixel implementation stayed
unchanged.

Run repository deterministic engine targets through the project CLI:

```sh
zig build peas -- test unit
zig build peas -- test replay
zig build peas -- test visual
zig build peas -- test integration
```

Runnable references:

- [Headless bounce](../../examples/bounce.zig)
- [Breakout simulation](../../examples/breakout_game.zig)

For a callback game, `up.testSupport.HeadlessGameRunner(Game)` owns a core canvas and `GameProtocol`. Pass deterministic `HeadlessFrame` values, then inspect `runner.capture().image_hash` and `runner.capture().commands`; no native window or browser is required.

`HeadlessGameRunner.capture().canvas_trace` is an opt-in structural trace of
the most recent `Game.draw()` call. It captures the public Canvas requests,
not SDL, GPU, batching, or pixels. Compare it structurally for a useful first
difference, or use its deterministic hash for compact regression output:

```zig
const capture = runner.capture();
const command_hash = try capture.canvas_trace.hash();

if (try expected_trace.firstDifference(capture.canvas_trace)) |difference| {
    var message_buffer: [512]u8 = undefined;
    const message = try up.testSupport.CanvasTrace.formatDifference(difference, &message_buffer);
    // Report `message` from the test harness.
    _ = message;
}
```

Use `up.testSupport.expectCanvasTraceEqual(expected, actual)` where a boolean
pass/fail assertion is enough. The trace is intentionally one draw frame, not
a replay timeline. Replay input is fixed-tick data; a normal host can perform
zero or more fixed updates before one draw. `HeadlessGameRunner.runReplay`
draws after each replay tick for its compact test protocol, so its capture is
the final such draw.

Canvas trace hashes use the `UPCT1` field-by-field encoding: a format marker,
fixed-width command count and tag values, then each logical field in order.
Integers are little-endian, `f32` values use their IEEE 754 bits, and no Zig
struct memory is hashed. Image and atlas resources are identified by
dimensions plus a deterministic digest of their decoded RGBA pixels, not by
pointers or backend handles. This is a logical rendering contract: equal
traces do not promise pixel-identical SDL GPU, WebGL2, or WebGPU output. Core
Canvas operations are fully traceable; GPU-material sprites, GPU particles,
and final post passes belong to the separate advanced renderer path and are
not represented by this Canvas trace yet.

`Canvas.drawSurface` is also a core trace operation. Its record uses the
surface's dimensions and current pixel digest—not its allocation address—plus
the destination rectangle, tint, and nearest/linear filter. A test therefore
detects a changed surface composition or changed surface contents while equal
surfaces from separate allocations retain the same logical trace. See
[Render surfaces](render-surfaces.md) for the target and lifetime rules.

## Seed + replay + headless runner

`up.preview.developer.InputReplayRecorder` records the normalized `Input` a game observes during each fixed update. It is independent of SDL, browser DOM events, and rendering. Record from the update boundary, then drive a fresh headless game with the resulting replay:

```zig
const seed: u64 = 42;
var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, seed);
defer recorder.deinit();

// In each fixed update:
try recorder.record(ctx.input.*);

var replay = try recorder.finish();
defer replay.deinit(allocator);

var runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(allocator, 320, 180, seed);
defer runner.deinit();
try runner.runReplay(replay);
// Assert a game-owned state field here. Seed Sprint asserts `score == 1`.
```

### Replay format reference

`replay.encode` emits portable, little-endian fixed-width bytes with an explicit magic. Seedless replays emit UPR2. `InputReplayRecorder.initSeeded` emits UPR3, which additionally records the `u64` simulation seed and the pinned Peas RNG algorithm ID. Parsing validates the version, algorithm, frame count, bounds, and finite numeric values. Existing UPR1 action-key fixtures and UPR2 binary replays remain accepted, but have no seed metadata; UPR1 only contains held action keys, so Peas reconstructs its press and release edges from successive frames.

A replay reproduces normalized fixed-tick input, not arbitrary game state. A seed-bearing replay can reject a headless runner initialized with a different seed. Equivalent results still require the same initialization path and deterministic game code. In particular, wall-clock reads, random sources other than the game-owned Peas RNG, unordered iteration, asynchronous asset completion, and platform-dependent floating-point computation remain the game's responsibility.

Save data is also external initial state. A `HeadlessGameRunner` owns an empty
`InMemorySaveStore` by default, so replay tests never touch native user data.
Preload `up.testSupport.InMemorySaveStore` and pass its capability to
`initWithSaveData` or `initSeededWithSaveData` when a test intentionally needs
saved settings or progression. [Save data](save-data.md) is not stored in a
UPR replay.

## Safari WebDriver

`zig build test-browser-safari` packages the browser proof game and drives Safari through its native WebDriver endpoint with forced `webgl2` and `webgpu` requests. Before running locally, enable WebDriver once with `safaridriver --enable`; Safari’s automation sessions are isolated from normal browsing data. The test writes the Safari version, WebDriver status, forced-renderer diagnostic, host artifacts, and screenshots under `zig-out/diagnostics/browser-safari/`.
