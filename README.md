# unpolished-peas

<div align="center">
    <img src="./asset/logo/peas-color-logo.png" width="30%">
</div>

A small Zig 2D engine with a callback-game starter and explicit core APIs.

## Start in 60 seconds

Requires Zig `0.15.2`. There is currently no published tag for this v0.1 development contract: `v0.0.4` is not a repository tag. Do not use the stale consumer command below from older revisions, and do not treat `main` as an installation target.

```sh
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
export ZIG_LOCAL_CACHE_DIR="$(mktemp -d)"
zig build test -Dwith_sdl=false
zig build browser -Dwith_sdl=false
```

This verifies the source checkout's headless and browser contracts.

**New to Peas?** Start with [Seed Sprint](templates/bounce/README.md): a
copyable one-screen game whose `src/game.zig` shows `Game.config`, `init`,
fixed-step `update`, Canvas `draw`, deterministic RNG, replay testing, and a
Canvas-command regression. A release preparation step must replace its
generated dependency coordinate with a real immutable tag URL and matching
hash before it is usable as an independent project.

Peas fits small authored 2D games, deterministic simulations, strong
headless testing, macOS/Linux native games, and browser-capable Zig projects.
It intentionally does not provide an engine-owned ECS, physics, 3D renderer,
editor, networking stack, or general scene hierarchy.

## Supported platforms

| Platform | Desktop runtime | Status |
| --- | --- | --- |
| macOS | SDL GPU | supported |
| Linux | SDL GPU | supported |
| Windows | SDL GPU | supported |
| Chromium, Firefox, Safari | WebGL 2 / WebGPU | preview |

The [capability matrix](docs/guides/capabilities.md) defines exact renderer, browser, and CI coverage.

## Compact API guide

- `sdl.playGame(Game)` runs the callback starter.
- `GameContext` provides input, canvas, assets, audio, and diagnostics.
- `ctx.requireCanvas()` returns the logical-pixel 2D canvas.
- `Canvas` draws rectangles, sprites, text, clips, and blends.
- `Config` controls window, fixed timestep, presentation, renderer, and assets.

Read the [core contract](docs/guides/core-contract.md), [game protocol](docs/guides/game-protocol.md), [rendering contract](docs/guides/rendering.md), and generated [core API](docs/api/core.md) before relying on behavior beyond the starter.

## Copyable examples

- [SDL bouncing square](examples/bounce_sdl.zig)
- [Seed Sprint starter](templates/bounce/README.md)
- [Explicit core loop](examples/explicit_loop.zig)
- [Top-down proof game](docs/proof-games/topdown.md)
- [Puzzle proof game](docs/proof-games/puzzle.md)
- [Platformer proof game](docs/proof-games/platformer.md)

## Release and local docs

Published generated projects pin one public archive URL and matching hash. No current tag provides that coordinate; see [release policy](docs/guides/releases.md).

Run `zig build docs` for offline documentation, or `zig build peas -- docs quickstart` to locate its local path. The [docs index](docs/index.md) links testing, platform, API, and migration details.
