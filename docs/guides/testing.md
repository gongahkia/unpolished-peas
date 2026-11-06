# Deterministic testing

Call reference: [HeadlessGameRunner and replay](../api/testing.md), including
generic returned-type methods, capture lifetimes and an executed Unicode replay.

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

`InputReplayRecorder.initSession` emits UPR4. It extends the UPR3 header with
a little-endian `u32` environment-byte count, followed by the environment and
the same fixed-width input frames. The environment contains three
length-prefixed identity strings, a save count, and entries containing a
length-prefixed key, a presence byte, and (when present) length-prefixed opaque
bytes. Lengths and counts are `u32` little-endian. Parsing rejects duplicate
keys, invalid identifiers, unsupported RNGs, non-finite input, truncation,
trailing data, and excessive sizes. UPR1–UPR3 encoding and decoding stay unchanged.

Recordings with any physical-key, text, composition or activation extension
emit **UPR5**, including optional seed and session metadata. Each frame keeps
the legacy 290-byte payload, followed by a little-endian `u16` extension size
and explicitly encoded extension bytes. Normalized-only recordings retain
UPR2/UPR3/UPR4 byte-for-byte, and UPR1–UPR4 remain readable. UPR5 validates
physical IDs, event/payload bounds, UTF-8, selection ranges and trailing bytes.
Its reproduction hash includes the extension; legacy hashes are unchanged.
See [input compatibility](input-v2-compatibility.md) for the complete layout.
The input workbench tests compare original and decoded replay game state,
logical traces and rendered pixels on native and browser-style Wasm hosts.

A replay reproduces normalized fixed-tick input, not arbitrary game state. A seed-bearing replay can reject a headless runner initialized with a different seed. Equivalent results still require the same initialization path and deterministic game code. In particular, wall-clock reads, random sources other than the game-owned Peas RNG, unordered iteration, asynchronous asset completion, and platform-dependent floating-point computation remain the game's responsibility.

Save data is also external initial state. A `HeadlessGameRunner` owns an empty
`InMemorySaveStore` by default, so replay tests never touch native user data.
Preload `up.testSupport.InMemorySaveStore` and pass its capability to
`initWithSaveData` or `initSeededWithSaveData` when a test intentionally needs
saved settings or progression. UPR1–UPR3 do not contain [save data](save-data.md).
Use the optional session workflow below when a bug depends on saved progress.

## Reproduce a session that depends on saved progress

Seed Sprint's compiled test, **“records a session then replays and reloads its
earned score”**, shows the complete workflow in
[`src/game.zig`](../../templates/starter/src/game.zig). It records a pickup,
encodes and parses the replay, compares the reproduced state, Canvas trace,
and pixels, then starts a fresh game that loads the earned high score.

Start recording before initialization reads or writes saves:

```zig
const identity = up.preview.developer.InputReplay.Environment.Identity{
    .game = "my-game",
    .build = "movement-v3",
    .assets = "levels-v2",
};
var recorder = try up.preview.developer.InputReplayRecorder.initSession(
    allocator, 60, seed, .{
        .identity = identity,
        .save_data = saves,
        .save_keys = &.{ "settings", "progress" },
    },
);
defer recorder.deinit();
// In each update, before changing game state:
try recorder.record(ctx.input.*);
// When recording ends:
var replay = try recorder.finish();
defer replay.deinit(allocator);
const bytes = try replay.encode(allocator);
defer allocator.free(bytes);
```

The recorder copies only the named keys, including whether each was missing
or present-but-empty. Writes during play cannot alter the captured start.
Capture is synchronous; do it while the game is not writing saves. Limits are
64 keys, 1 MiB of total saved bytes, and 256 bytes per nonempty identity field.
The file can contain the selected save contents, so select only the keys the
reproduction needs. Peas never scans the store or uploads recordings.

Games choose meaningful build and asset identifiers: a release label, source
revision, or content hash works. Update them when the corresponding code or
assets change; Peas compares supplied values and does not infer them from the
filesystem. Recording has no overhead until a game opts into it.

```zig
var replay = try up.preview.developer.parseInputReplay(allocator, bytes);
defer replay.deinit(allocator);
var runner = try up.testSupport.HeadlessGameRunner(Game).initReplay(
    allocator, 320, 180, replay, identity,
);
defer runner.deinit();
try runner.runReplay(replay);
```

`initReplay` checks identity before calling `Game.init`, supplies the recorded
seed, and copies captured values into a private in-memory store. Unlisted keys
are absent; list every save the initialization and run depend on. Playback
never writes the user's saves. Mismatches report `ReplayGameMismatch`,
`ReplayBuildMismatch`, or `ReplayAssetsMismatch`. A session needs a fresh
runner; replaying after updates returns `ReplayAlreadyStarted`. A normal
seeded runner cannot accidentally ignore session saves (`ReplayEnvironmentRequired`).
Older recordings can use `initReplay(..., replay, null)` or the existing
initializers. `runReplay` validates every input frame before executing any.

This reproduces controlled inputs and initial conditions. Games still own
their state layout and deterministic simulation; it does not capture arbitrary
memory, asynchronous work, live asset edits, or wall-clock observations.

## Step simulation separately from drawing

`runner.step(snapshot, elapsed_seconds)` executes one update without drawing.
Pass `input.snapshot()` or a recorded `replay.frames[index]`, using the same
fixed duration as the runtime. `runner.draw(alpha)` captures a draw without
advancing simulation. `runner.ticks` counts successful updates. This lets a
test investigate controller or pointer input, simulate catch-up updates, or
verify that extra draws do not change game state. Consume transient edges
once when building successive snapshots (`snapshot.clearTransient()` keeps
held state); recorded frames already contain the correct per-tick edges.

`run` and `runReplay` remain the convenient update-and-draw helpers. Captures
borrow the runner's most recent draw and remain valid until its next draw or
destruction. These are developer test tools and need no window or GPU.

For a portable game-state digest, use `StateHash.updatePortable` on selected
fixed-width fields or pointer-free structs, and `updateBytes` for byte strings.
Integers use little-endian encoding, floats retain their exact bits, structs
visit declared fields without padding, arrays include a `u64` length, and
optionals include a presence byte. Keep the field schema stable and use `u32`
or `u64` rather than target-sized integers. Pointers and slices are rejected
by `updatePortable`; game code selects what constitutes its meaningful state.
The legacy `updateValue` remains available with its existing native-memory
hashes so existing goldens retain their meaning. `zig build test-browser-replay`
exercises recording, parsing, isolated playback, and the portable hash on the
freestanding Wasm target; it is also included in `test-browser-wasm-host`.

## Safari WebDriver

`zig build test-browser-safari` packages the browser proof game and drives Safari through its native WebDriver endpoint with forced `webgl2` and `webgpu` requests. Before running locally, enable WebDriver once with `safaridriver --enable`; Safari’s automation sessions are isolated from normal browsing data. The test writes the Safari version, WebDriver status, forced-renderer diagnostic, host artifacts, and screenshots under `zig-out/diagnostics/browser-safari/`.

## Integrated downstream workflow

Run `zig build test-starter-persistence -Dwith_sdl=false` and
`zig build test-portable-conformance -Dwith_sdl=false` for an integrated check.
The [portable workflow guide](portable-conformance.md) describes the verified
archive dependency, isolated native save/restart, real browser interactions,
failed-init cleanup and session replay from captured initial saves. The fixture
game uses public APIs throughout. These checks require a usable native display
and the repository's Chromium/Playwright tooling.
