# unpolished-peas

<div align="center">
    <img src="./asset/logo/peas-color-logo.png" width="30%">
</div>

A small Zig 2D engine with a callback-game starter and explicit core APIs.

## Start in 60 seconds

Requires Zig `0.15.2`. Start from the published `v0.0.4` checkout with empty Zig caches; do not install from `main`.

```sh
git clone --depth 1 --branch v0.0.4 https://github.com/gongahkia/unpolished-peas.git
cd unpolished-peas
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
export ZIG_LOCAL_CACHE_DIR="$(mktemp -d)"
zig build new -- game
cd game
zig build run -- --frames 2
```

This creates the callback [starter](templates/bounce/src/main.zig): set `Game.config`, then implement `init`, fixed-step `update`, and `draw`. The default dependency fetches pinned SDL3 source; no system SDL installation is required.

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
- [Explicit core loop](examples/explicit_loop.zig)
- [Top-down proof game](docs/proof-games/topdown.md)
- [Puzzle proof game](docs/proof-games/puzzle.md)
- [Platformer proof game](docs/proof-games/platformer.md)

## Release and local docs

Generated projects pin one public archive URL and matching hash. Upgrade them together from the reviewed starter manifest; see [release policy](docs/guides/releases.md).

Run `zig build docs` for offline documentation, or `zig build peas -- docs quickstart` to locate its local path. The [docs index](docs/index.md) links testing, platform, API, and migration details.
