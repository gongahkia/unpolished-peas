# unpolished-peas

<div align="center">
    <img src="./asset/logo/peas-color-logo.png" width="30%">
</div>

A small Zig 2D engine with a callback-game starter and explicit core APIs.

## Start in 60 seconds

Requires Zig `0.15.2`. The intended first public release is `v0.1.0`, but no
tag has been published yet. Do not use `main` as an installation target.

```sh
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
export ZIG_LOCAL_CACHE_DIR="$(mktemp -d)"
zig build test -Dwith_sdl=false
zig build browser -Dwith_sdl=false
```

This verifies the source checkout's headless and browser contracts.

**New to Peas?** Start with [Seed Sprint](templates/starter/README.md): a
copyable one-screen game whose tiny `src/main.zig` configures the desktop host
and whose `src/game.zig` shows `init`, fixed-step `update`, Canvas `draw`,
deterministic RNG, replay testing, and a Canvas-command regression. A release
preparation step must replace its
generated dependency coordinate with a real immutable tag URL and matching
hash before it is usable as an independent project. The checked-in source
template deliberately contains no misleading release URL or package hash.

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
- `GameContext` provides input, canvas, and optional small save-data storage.
- `ctx.requireCanvas()` returns the logical-pixel 2D canvas.
- `ctx.requireSaveData()` returns a host-owned opaque-byte save store.
- `Canvas` draws rectangles, sprites, text, clips, and blends.
- `Config` controls window, fixed timestep, presentation, renderer, and assets.

Read the [core contract](docs/guides/core-contract.md), [game protocol](docs/guides/game-protocol.md), [save-data guide](docs/guides/save-data.md), [rendering contract](docs/guides/rendering.md), and generated [core API](docs/api/core.md) before relying on behavior beyond the starter.

## Copyable examples

- [SDL bouncing square](examples/bounce_sdl.zig)
- [Seed Sprint starter](templates/starter/README.md)
- [Explicit core loop](examples/explicit_loop.zig)
- [Top-down proof game](docs/proof-games/topdown.md)
- [Puzzle proof game](docs/proof-games/puzzle.md)
- [Platformer proof game](docs/proof-games/platformer.md)

## Release and local docs

Published generated projects pin one public archive URL and matching hash. No
current tag provides that coordinate; see the [installation guide](docs/guides/installation.md)
and [release policy](docs/guides/releases.md).

Run `zig build docs` for offline documentation, or `zig build peas -- docs quickstart` to locate its local path. The [docs index](docs/index.md) links testing, platform, API, and migration details.
