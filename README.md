# unpolished

Small Zig 2D engine experiment.

## API Goal

Unpolished should feel as simple to start with as raylib, LÖVE, and Ebitengine:

- draw a sprite, play a sound, read input, and reload an asset with minimal setup.
- keep tiny games in one readable file without framework ceremony.
- make the simple path obvious, while preserving explicit Zig control flow.
- treat long examples as temporary scaffolding until the public API supports shorter ones.

## Tiny Start

```zig
const up = @import("unpolished");
const sdl = @import("unpolished_sdl3");

const Game = struct {
    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.rect(18, 18, 28, 28, up.Color.rgb(255, 198, 74));
        ctx.text("HELLO", 8, 8, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.play(.{ .width = 80, .height = 60, .scale = 6 }, Game);
}
```

## Positioning

- Not blank space: Mach, zig-gamedev, jok, Delve, and several small engines exist.
- Gap: no obvious widely adopted Zig equivalent of LÖVE/raylib/Ebitengine with a 2D-first API and tiny first-win path.
- Bet: win by being the fastest path from `zig build run` to a visible 2D game, with headless tests and explicit control flow.
- Non-goal: compete with Mach on broad WebGPU/full-engine scope or with zig-gamedev as a toolbox.

## Differentiators

- 2D-only first; no editor and no 3D surface until the 2D loop is excellent.
- Headless renderer for CI screenshots, examples, and deterministic tests.
- Reloadable file assets via polling `mtime`, so iteration works before native file watchers.
- Built-in debug text with no font dependency.
- Public API stays explicit: user code owns update/render order.

## Commands

```sh
zig build test
zig build run-bounce
zig build run-bounce-sdl
zig build dev-bounce
zig build run-minimal
zig build test-scenes
```

`run-bounce` renders `zig-out/bounce.ppm`.
`run-bounce-sdl` opens an SDL_GPU window.
`dev-bounce` opens a PNG/text live-reload demo.
`test-scenes` runs deterministic headless scene hashing.

## Current API

- `Vec2`, `Rect`
- `Color`
- `Input`, `Key`
- `StepClock`
- `Canvas`, `Sprite`
- `Canvas.drawImage`
- `Canvas.drawText`
- `AssetFile`
- `AssetStore`
- `Image`
- `unpolished_sdl3.play`, `unpolished_sdl3.Context`
- `unpolished_sdl3.run` for lower-level control

## Next build targets

1. Minimal audio: `loadWav`, `playSound`, looping music, volume.
2. Sprite ergonomics: centered draw helpers, texture atlas, frame animation.
3. Starter template: one command to copy a tiny playable project.
4. Shader API with one strict pixel-effect example.
5. Web export after desktop loop, assets, and audio feel solid.
