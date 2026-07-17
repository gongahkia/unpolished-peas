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

`sdl.playGame(Game)` dispatches a game with `GameContext` callbacks through this protocol. Legacy `sdl.Context` callbacks remain available for existing games; `sdl.run` remains the explicit-loop escape hatch.

`GameProtocol.init` rejects a second initialization. `update` and `draw` reject calls before a successful initialization. Callback failures preserve their original error and are available through `lastFailure()` with an `init`, `update`, or `draw` phase. The protocol does not call a deinitializer; game-owned resources remain game-owned.
