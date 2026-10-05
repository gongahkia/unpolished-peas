# Start here

Peas is a small Zig framework for deterministic, testable 2D games. The
fastest way to understand it is to run Seed Sprint, read its two source files,
then grow into the focused guides linked below.

## Requirements and release status

Use Zig `0.15.2`. The first public release is prepared as `v0.1.0`, but has
**not** been published. Do not put `main` into a game manifest or copy the
future dependency URL from an old document. The [installation guide](installation.md)
labels the future release declaration explicitly and explains the current
external-project limitation.

## Five-minute source-checkout path

From a Peas checkout, run the canonical starter without needing a generated
project or a package URL:

```sh
zig build test-starter -Dwith_sdl=false
zig build run-starter
```

The test is headless; the run command opens Seed Sprint. Arrow keys or a
gamepad move, Space/South dashes, and Enter/Start restarts. Read these files
in order:

1. [`templates/starter/src/main.zig`](../../templates/starter/src/main.zig) —
   desktop configuration and the tiny host-facing wrapper.
2. [`templates/starter/src/game.zig`](../../templates/starter/src/game.zig) —
   persistent game state, `init`, fixed-step `update`, Canvas `draw`, seed,
   save data, audio, and the deterministic test.

The source checkout can also compile the starter browser runtime and native
package layout:

```sh
zig build browser-starter -Dwith_sdl=false
zig build package-starter
```

The full self-contained `zig build web` browser directory is the command for a
released or release-fixture standalone Seed Sprint project; see
[browser and packaging](installation.md#browser-and-package) for that distinct
workflow.

## A minimal game

This exact program is the compiled
[`examples/tutorial_game_protocol.zig`](../../examples/tutorial_game_protocol.zig)
source. `zig build check-examples` compiles it, and this checkout can run it
with `zig build run-tutorial-game-protocol`.

<!-- BEGIN tutorial-game-protocol -->
```zig
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

/// This deliberately small program is the compiled source shown in the
/// Start Here guide. Seed Sprint is the next step when a game needs actions,
/// deterministic RNG, saves, audio, and tests.
const Game = struct {
    pub const config: sdl.Config = .{
        .title = "Peas first game",
        .width = 160,
        .height = 90,
        .scale = 5,
        .clear_color = up.core.Color.rgb(14, 18, 24),
    };

    player_x: f32 = 76,

    pub fn init(_: *Game, _: *up.core.GameContext) !void {}

    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        if (ctx.input.isDown(.left)) self.player_x -= 48 * elapsed_seconds;
        if (ctx.input.isDown(.right)) self.player_x += 48 * elapsed_seconds;
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.rgb(14, 18, 24));
        canvas.fillRect(@intFromFloat(self.player_x), 42, 8, 8, up.core.Color.rgb(255, 198, 74));
        canvas.drawText("LEFT / RIGHT", 48, 12, up.core.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
```
<!-- END tutorial-game-protocol -->

`init` creates initial game state. `update` is simulation: Peas can run zero
or more fixed updates before a single presentation `draw`, so gameplay,
collision, timers, and input belong there. `draw` translates current state
into Canvas requests. This example owns no allocator-backed resource, so it
has no `deinit`; add `deinit` when a game owns an `Image`, `Font`, `ActionMap`,
or `RenderSurface`.

## What to learn next

1. [Seed Sprint](../../templates/starter/README.md) for the first complete
   small game.
2. [Input and ActionMap](input.md) for keyboard/gamepad actions and edges.
3. [Authored image and font assets](image-assets.md) for normal embedded art.
4. [Testing](testing.md) for seed, replay, headless state, Canvas trace, and
   pixel regression.
5. [Neon Siege](../../dogfood/neon-siege/README.md) only when you want a
   larger public-API reference.
