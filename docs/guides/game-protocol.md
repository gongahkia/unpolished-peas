# Game protocol

`up.core.GameProtocol(Game)` is the backend-neutral v0.1 lifecycle. It borrows a game value and never allocates, moves, or deinitializes that value. Hosts create `up.core.GameContext`, call `init` once, call `update` for each simulated step, and call `draw` once for each presented frame.

```zig
const Game = struct {
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void;
    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void;
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void;
};
```

`GameContext` exposes read-only normalized `input`. Runtime hosts populate a canvas capability; games obtain it with `requireCanvas`, which fails outside a runtime host. The host owns asset, audio, and presentation handling. This keeps callback signatures backend-neutral while allowing core drawing. During `update`, `elapsed_seconds` and `ctx.elapsed_seconds` are the same non-negative finite fixed simulation step; `ctx.interpolation_alpha` is zero. During `draw`, `ctx.interpolation_alpha` is the remaining fixed-step fraction in `[0, 1]`.

Desktop and browser hosts use an accumulator with a five-step catch-up cap. A non-paused frame clamps elapsed wall time to five fixed steps, runs zero to five `update` calls at the fixed step in seconds, then runs exactly one `draw` with the remaining interpolation fraction. Desktop selects the fixed rate through `sdl.Config.fixed_hz`; the browser rate is 60 Hz. A paused frame runs no updates and draws with zero alpha; its accumulated remainder is retained. Browser visibility changes enter that pause state and reset the timestamp, so time while hidden is discarded rather than replayed on resume.

`sdl.playGame(Game)` dispatches a game with `GameContext` callbacks through this protocol. Legacy `sdl.Context` callbacks remain available for existing games; `sdl.run` remains the explicit-loop escape hatch.

The browser bundle runs the same callback fixture through its Wasm host. Select `?renderer=webgl2` explicitly; a `webgpu` request fails visibly because WebGPU is unsupported in the current [capability matrix](capabilities.md).

`GameProtocol.init` rejects a second initialization. `update` and `draw` reject calls before a successful initialization. Callback failures preserve their original error and are available through `lastFailure()` with an `init`, `update`, or `draw` phase. The protocol does not call a deinitializer; game-owned resources remain game-owned.

`up.testSupport.HeadlessGameRunner(Game)` runs the same callback contract with scripted `HeadlessFrame` input, a deterministic core canvas capture, and retained shared render commands for tests.
