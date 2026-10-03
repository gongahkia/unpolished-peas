# Game protocol

`up.core.GameProtocol(Game)` is the backend-neutral v0.1 lifecycle. It borrows a game value and never allocates, moves, or deinitializes that value. Hosts create `up.core.GameContext`, call `init` once, call `update` for each simulated step, and call `draw` once for each presented frame.

```zig
const Game = struct {
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void;
    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void;
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void;
    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void; // optional
};
```

`GameContext` exposes read-only normalized `input`. Runtime hosts populate a canvas capability; games obtain it with `requireCanvas`, which fails outside a runtime host. Normal native, browser, and headless protocol hosts also provide a host-owned allocator through `requireAllocator`. A game uses that allocator for values it owns, such as `RenderSurface`, `Image`, `Atlas`, and `Font`, and releases those values from its optional `deinit` callback. They may also provide `save_data`, a backend-neutral `SaveStore` for small game-owned byte blobs; `requireSaveData` makes absence explicit. Normal native, browser, and headless protocol hosts also provide `audio`, a small sound-effect capability; loading is available during `init`, while playback can still be blocked or unavailable and must be handled as a recoverable output failure. The host owns the allocator, audio, presentation, and save location; game code owns resources it creates through those capabilities. This keeps callback signatures backend-neutral while allowing core drawing and persistence. During `update`, `elapsed_seconds` and `ctx.elapsed_seconds` are the same non-negative finite fixed simulation step; `ctx.interpolation_alpha` is zero. During `draw`, `ctx.interpolation_alpha` is the remaining fixed-step fraction in `[0, 1]`.

Hosts may set `ctx.simulation_seed` before `init`. A game that needs repeatable random initialization should require that value and store its own `up.core.DeterministicRng`, for example `self.rng = up.core.DeterministicRng.init(ctx.simulation_seed orelse return error.MissingSimulationSeed)`. Peas does not provide a global RNG: the game owns consumption order and therefore its deterministic state.

`DeterministicRng` takes one stable `u64` seed and pins PCG XSH-RR 64/32 v1: it advances zero state, adds the seed, and advances once using the fixed PCG stream increment `1442695040888963407`. The exact `nextU32` sequence is covered by fixed compatibility vectors. `nextU64` joins two consecutive 32-bit values (first high), `uintBelow(upper)` is uniformly distributed in `[0, upper)` and rejects zero, and `float01` produces one of `2^24` `f32` values in `[0, 1)`. This makes integer random values portable across Peas targets; it does not make arbitrary game floating-point computation bit-identical across hardware.

Persistent bytes are environmental input, not replay metadata. A reproducible
test therefore needs the same initial save-store contents as well as the same
seed and normalized fixed-tick replay. `HeadlessGameRunner` defaults to an
empty in-memory store and can receive an explicitly preloaded one. See the
[save-data guide](save-data.md) for key rules, native locations, browser
`localStorage`, and error handling.

Desktop and browser hosts use an accumulator with a five-step catch-up cap. A non-paused frame clamps elapsed wall time to five fixed steps, runs zero to five `update` calls at the fixed step in seconds, then runs exactly one `draw` with the remaining interpolation fraction. Desktop selects the fixed rate through `sdl.Config.fixed_hz` and may supply `sdl.Config.simulation_seed`; the browser rate is 60 Hz. A paused frame runs no updates and draws with zero alpha; its accumulated remainder is retained. Browser visibility changes enter that pause state and reset the timestamp, so time while hidden is discarded rather than replayed on resume.

`sdl.playGame(Game)` dispatches a game with `GameContext` callbacks through this protocol. Legacy `sdl.Context` callbacks remain available for existing games; `sdl.run` remains the explicit-loop escape hatch.

The browser bundle runs the same callback fixture through its Wasm host. Select `?renderer=webgl2`, `?renderer=webgpu`, or `?renderer=auto`; auto prefers a ready WebGPU backend and records a deterministic WebGL 2 fallback when unavailable. Chromium WebGPU is [preview](capabilities.md), while Firefox and Safari WebGPU remain outside the v0.1 runtime contract.

`GameProtocol.init` rejects a second initialization. `update` and `draw` reject calls before a successful initialization. If `Game` declares `deinit`, the host calls it once after a successful initialization and before releasing context capabilities. Callback failures preserve their original error and are available through `lastFailure()` with an `init`, `update`, `draw`, or `deinit` phase. Games without `deinit` retain the three-callback protocol.

`up.testSupport.HeadlessGameRunner(Game)` runs the same callback contract with scripted `HeadlessFrame` input, a deterministic core canvas capture, and retained shared render commands for tests.
