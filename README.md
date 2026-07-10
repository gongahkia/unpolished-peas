# unpolished

Small Zig 2D engine experiment.

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
- `unpolished_sdl3.run`

## Next build targets

1. Audio.
2. Texture atlas + sprite animation.
3. Shader API with strict examples.
4. Optional game-code hot reload.
5. Web export.
