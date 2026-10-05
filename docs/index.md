# Peas learning path

Peas is a small Zig framework for deterministic, testable 2D games. Start
with the smallest complete project, then add only the concepts your game needs.

## 1. First 10 minutes

1. [Start here](guides/quickstart.md) — requirements, the current unreleased
   checkout path, a compiled `GameProtocol` program, and fixed-step basics.
2. [Seed Sprint](../templates/starter/README.md) — the canonical beginner
   project: read `src/main.zig`, then `src/game.zig`.
3. [Game protocol](guides/game-protocol.md) — lifecycle, ownership, and the
   fixed-step contract in more detail.

## 2. Build a small game

- [Input and ActionMap](guides/input.md)
- [Authored images and fonts](guides/image-assets.md)
- [Deterministic sprite-frame animation](guides/sprite-animation.md)
- [Sound effects and music](guides/audio-assets.md)
- [Small save data](guides/save-data.md)
- [Canvas, camera, and presentation](guides/rendering.md)
- [CPU RenderSurface composition](guides/render-surfaces.md)

## 3. Make it deterministic and testable

- [Testing: seed, replay, headless state, Canvas trace, pixels](guides/testing.md)
- [v0.1 core contract](guides/core-contract.md)

## 4. Ship it

- [Installation and external-project status](guides/installation.md)
- [Platform status](guides/platforms.md)
- [Releases and support](guides/releases.md)

## 5. Read a larger reference only when ready

- [Neon Siege](../dogfood/neon-siege/README.md) is the public-API reference
  game for owned resources, sprites, camera, audio/music, save data,
  RenderSurface, deterministic tests, diagnostics, and hot reload.
- [Lantern Leap](../dogfood/lantern-leap/README.md) is the second reference
  game: a scrolling platformer that keeps gravity, AABB collision, handcrafted
  level data, checkpoints, and animation-state selection in ordinary game
  code while using the same public Peas package boundary.
- [Advanced 2D](guides/advanced-2d.md) covers `Renderer2D`, materials,
  particles, and post passes. Ordinary Canvas games do not need this layer.
- [Developer diagnostics](guides/developer-diagnostics.md) and
  [developer asset reload](guides/developer-asset-reload.md) are opt-in native
  development tools. [Developer-tools environment reference](guides/developer-tools.md)
  lists their explicit controls.
- [Browser development](guides/browser-development.md) adds an opt-in local
  watch, rebuild, serve, and full-page-refresh loop after the normal browser
  build workflow is already familiar.

## Which example should I read?

| Goal | Read this |
| --- | --- |
| Learn Peas from scratch | [Seed Sprint](../templates/starter/README.md) |
| See a compact `init` / `update` / `draw` program | [compiled tutorial source](../examples/tutorial_game_protocol.zig) |
| See a complete small game | [Neon Siege](../dogfood/neon-siege/README.md) |
| See a second genre with scrolling/platform collision | [Lantern Leap](../dogfood/lantern-leap/README.md) |
| Learn deterministic replay and rendering regression | [Testing](guides/testing.md) and Seed Sprint's `src/game.zig` |
| Learn materials, particles, or post passes | [Advanced 2D](guides/advanced-2d.md) |
| Find exact API/CI contract details | [Core contract](guides/core-contract.md), [capability matrix](guides/capabilities.md), and [Core API](api/core.md) |

## Post-v0.1 authoring contract

[Authoring-experience freeze](guides/authoring-experience-freeze.md) records
which post-v0.1 additions are recommended game APIs, which remain experimental
developer tooling, and why Seed Sprint, Neon Siege, and Lantern Leap are the
three canonical projects. It is an architecture-milestone record, not a
published `v0.2.0` release.

## Reference and maintenance material

- [Capability matrix](guides/capabilities.md)
- [CI](guides/ci.md)
- [Browser renderer diagnostics](guides/browser-diagnostics.md)
- [v0.1 migrations](guides/migrations.md)

Run `zig build docs` to emit this Markdown set under `zig-out/docs/`, or use
`zig build peas -- docs quickstart` to locate the generated start page.
