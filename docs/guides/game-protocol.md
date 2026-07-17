# Game protocol

`up.GameProtocol(Game)` is the backend-neutral v0.1 lifecycle. It borrows a game value and never allocates, moves, or deinitializes that value. Hosts create `up.GameContext`, call `init` once, call `update` for each simulated step, and call `draw` once for each presented frame.

```zig
const Game = struct {
    pub fn init(self: *Game, ctx: *up.GameContext) !void;
    pub fn update(self: *Game, ctx: *up.GameContext, elapsed_seconds: f32) !void;
    pub fn draw(self: *Game, ctx: *up.GameContext) !void;
};
```

`GameContext` exposes read-only normalized `input`. Games own their rendering and audio values, keeping the protocol independent of desktop and browser backends. During `update`, `elapsed_seconds` and `ctx.elapsed_seconds` are the same non-negative finite fixed simulation step; `ctx.interpolation_alpha` is zero. During `draw`, `ctx.interpolation_alpha` is the remaining fixed-step fraction in `[0, 1]`.

`GameProtocol.init` rejects a second initialization. `update` and `draw` reject calls before a successful initialization. Callback failures preserve their original error and are available through `lastFailure()` with an `init`, `update`, or `draw` phase. The protocol does not call a deinitializer; game-owned resources remain game-owned.
