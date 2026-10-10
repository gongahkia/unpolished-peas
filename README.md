# `Unpolished Peas` 🫛

A small framework for building 2D games in [Zig]() that compiles to [native]() and [browser]() builds.

## Rationale

Peas is for games that need predictable simulation and straightforward testing without an engine owning the game's rules. Your Zig code owns its state, collision, and level behavior; Peas supplies the loop, input, drawing, assets, and platform hosts.

It deliberately does not provide an engine-owned ECS, physics, 3D renderer, editor, networking stack, large UI framework, or general scene hierarchy.

## Stack

* [Zig 0.15.2]()
* [SDL3]()
* [WASM]()

## Features

- `sdl.playGame(Game)` runs a `GameProtocol` game with fixed-step updates.
- `GameContext` provides normalized input, an allocator, a Canvas, and optional save and audio capabilities.
- `ctx.requireCanvas()` gives a game its logical-pixel 2D canvas for rectangles, sprites, text, clips, and blends.
- `RenderSurface` owns an offscreen Canvas for deterministic 2D composition.
- `ctx.requireSaveData()` gives a game a host-owned store for small opaque save blobs.
- `Config` controls the window, fixed timestep, presentation, renderer, and optional runtime assets.

## Usage

> [!NOTE]
> Peas is preparing its first public `v0.1.0` release. No immutable package has been published, so use this checkout for now rather than depending on `main`. The checked-in starter intentionally has no placeholder release URL or hash. See [installation](docs/guides/installation.md) for the eventual immutable-package workflow.

1. Follow the [5–10 minute Start Here guide](docs/guides/quickstart.md).
2. Read and run [Seed Sprint](templates/starter/README.md), the canonical beginner project.
3. From this checkout, run the starter's game and tests:

   ```sh
   zig build test-starter -Dwith_sdl=false
   zig build run-starter
   ```

4. Once familiar with the starter, read [Neon Siege](dogfood/neon-siege/README.md) for a larger public-API example and [Lantern Leap](dogfood/lantern-leap/README.md) for a scrolling platformer whose collision and level rules stay in game code.

## Examples

| Need | Read |
| --- | --- |
| First Peas game | [Seed Sprint](templates/starter/README.md) |
| Minimal lifecycle | [Tutorial `GameProtocol` example](examples/tutorial_game_protocol.zig) |
| Complete reference game | [Neon Siege](dogfood/neon-siege/README.md) |
| Scrolling platformer reference | [Lantern Leap](dogfood/lantern-leap/README.md) |
| Replay, state, and Canvas regression | [Testing guide](docs/guides/testing.md) |
| Advanced materials or particles | [Advanced 2D guide](docs/guides/advanced-2d.md) |

## Support

The [platform status](docs/guides/platforms.md) page records build/package evidence separately from actual runtime validation. The [capability matrix](docs/guides/capabilities.md) records renderer and browser contracts and CI coverage.

## Other docs

- [Learning path](docs/index.md) — the recommended order for guides, from the starter to advanced topics. Start with the beginner material before the core contract or advanced renderer reference unless you need those details.
- [Game protocol](docs/guides/game-protocol.md) and [core contract](docs/guides/core-contract.md) — lifecycle and public API details.
- [Installation](docs/guides/installation.md) and [release policy](docs/guides/releases.md) — the unpublished release status and future archive workflow. Published generated projects will pin one immutable archive URL and matching hash; no current tag provides that coordinate.
- [Local documentation](docs/index.md) — run `zig build docs` to generate offline docs, or `zig build peas -- docs quickstart` to locate the local start page. The index also links testing, platform, API, and migration details.
