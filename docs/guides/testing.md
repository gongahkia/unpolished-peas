# Testing

Run deterministic engine targets through the project CLI:

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

## Fixed-tick input replay

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
```

`replay.encode` emits portable, little-endian fixed-width bytes with an explicit magic. Seedless replays emit UPR2. `InputReplayRecorder.initSeeded` emits UPR3, which additionally records the `u64` simulation seed and the pinned Peas RNG algorithm ID. Parsing validates the version, algorithm, frame count, bounds, and finite numeric values. Existing UPR1 action-key fixtures and UPR2 binary replays remain accepted, but have no seed metadata; UPR1 only contains held action keys, so Peas reconstructs its press and release edges from successive frames.

A replay reproduces normalized fixed-tick input, not arbitrary game state. A seed-bearing replay can reject a headless runner initialized with a different seed. Equivalent results still require the same initialization path and deterministic game code. In particular, wall-clock reads, random sources other than the game-owned Peas RNG, unordered iteration, asynchronous asset completion, and platform-dependent floating-point computation remain the game's responsibility.

## Safari WebDriver

`zig build test-browser-safari` packages the browser proof game and drives Safari through its native WebDriver endpoint with forced `webgl2` and `webgpu` requests. Before running locally, enable WebDriver once with `safaridriver --enable`; Safari’s automation sessions are isolated from normal browsing data. The test writes the Safari version, WebDriver status, forced-renderer diagnostic, host artifacts, and screenshots under `zig-out/diagnostics/browser-safari/`.
