# Start here

Peas is a small Zig framework for deterministic, testable 2D games. The
fastest way to understand it is to generate Seed Sprint, read its two source
files, then grow into the focused guides linked below.

## Before you start

Use Zig `0.15.2` and a current Peas source checkout; see
[installation](installation.md#requirements) for prerequisites.
This guide uses a local dependency and includes changes after the published
tag. [Release status](releases.md#current-release) records package availability;
an older tagged checkout may not provide this workflow.

## Create and play

From a Peas checkout, create your own game next to the engine repository:

```sh
zig build peas -- new ../my-game
cd ../my-game
zig build
zig build run
```

The generator writes a relative `.path` dependency pointing to this Peas
checkout. No manifest repair or published package is needed. Keep the checkout
available at that relative location while developing; its changes are picked
up by subsequent builds. SDL3 is fetched and built from the pinned dependency,
so the first native build needs network access and can take longer.

`run` opens Seed Sprint. Arrow keys or a gamepad move, Space/South dashes,
and Enter/Start restarts. Close the window to return to the terminal. Read
these generated files in order (links show the same source in this checkout):

1. [`templates/starter/src/main.zig`](../../templates/starter/src/main.zig) —
   desktop configuration and the tiny host-facing wrapper.
2. [`templates/starter/src/game.zig`](../../templates/starter/src/game.zig) —
   persistent game state, `init`, fixed-step `update`, Canvas `draw`, seed,
   save data, audio, and the deterministic test.

Edit `src/game.zig` to change gameplay, then rerun `zig build run`. Keep
portable game logic there; `src/main.zig` supplies native window configuration
and forwards callbacks. Assets under `src/assets/` can be embedded from game
code without another build module; see the [asset recipes](asset-recipes.md).

## Test and run in a browser

From the generated game directory:

```sh
zig build test
zig build web
python3 -m http.server --bind 127.0.0.1 --directory zig-out/web 8000
```

`test` runs the starter's headless deterministic checks without opening a
window. With Python 3 available, the last command serves the web output; open
`http://127.0.0.1:8000/`, focus the game and use the same controls. Sound needs
a user interaction. Press Ctrl-C in the terminal to stop serving. Another
HTTP server works too; opening `index.html` directly is unsupported.

For automatic rebuild and full-page refresh, use `zig build dev-web` instead
of the manual server. See [browser development](browser-development.md).
Browser renderers remain preview; [platform evidence](platforms.md) records
which workflows were exercised. A Canvas game can use automatic renderer
selection; games opting into GPU surface composition must choose WebGL 2 as
described in the [rendering guide](rendering.md#choose-a-rendering-path).

## Package your game

From the generated game directory, `zig build package` produces the desktop
executable-plus-assets layout. The browser directory from `zig build web`
can be served by a static host. See
[output layout and distribution limits](installation.md#browser-and-package).
Release pinning is an optional dependency mode documented in
[installation](installation.md#pin-a-prepared-release).

## Try examples from the engine checkout

To evaluate the reference game without generating a project, the engine
checkout still offers `zig build run-starter` and
`zig build test-starter -Dwith_sdl=false`.

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
3. [Portable asset recipes](asset-recipes.md) for embedded images, fonts and sheets.
4. [Testing](testing.md) for seed, replay, headless state, Canvas trace, and
   pixel regression.
5. [Neon Siege](../../dogfood/neon-siege/README.md) only when you want a
   larger public-API reference.
