# 72

72 is a Go-first, general-purpose game-engine runtime in active development.
It is 2D-first and targets Linux, Windows, macOS, and WebAssembly. The current
release is a runtime SDK, not an editor or a complete production toolchain.

Games own their rules and content. The engine owns reusable runtime concerns:

- application lifecycle, platform-neutral input actions, cameras, and ordered layers;
- an ECS world, deterministic system scheduler, plugins, and ECS-backed scene transforms;
- typed reloadable assets, audio mixer state, deterministic AABB 2D physics, retained UI layout, diagnostics, and a high-level 2D render-command model.

The public packages are rooted at `github.com/gongahkia/72/engine`:

| Package | Responsibility |
| --- | --- |
| `engine` | application lifecycle, input, cameras, Canvas compatibility layers, command layers, plugins |
| `engine/ecs` | entities, components, resources, and ordered schedules |
| `engine/scene` | ECS-backed parent/child transform hierarchy |
| `engine/assets` | typed asset handles, reload hooks, async loading, manifests |
| `engine/audio` | backend-neutral playback and bus mixing |
| `engine/physics` | deterministic AABB 2D bodies, contacts, and queries |
| `engine/ui` | retained layout, focus, and pointer hit testing |
| `engine/render` | backend-neutral high-level 2D commands and portable texture sources |
| `engine/diagnostics` | counters and duration summaries |

## Wukong example

[Wukong](example/wukong) is an example game written against 72. It is not part
of the engine API or a definition of engine policy. It owns its deterministic
procedural platforming simulation, assets, replay tooling, and playtest rules;
it demonstrates the kind of game a 72 user can write.

```sh
make example-run
```

## Renderer transition

`engine/ebiten` is the current compatibility adapter. It translates 72's
platform-neutral lifecycle, input, Canvas compatibility drawing surface, and
high-level render command layers to Ebitengine. Ebitengine types do not appear
in the public engine API. Runtime-owned portable texture data is converted to
and cached as Ebitengine GPU images only inside this adapter.

72 will replace this adapter with an engine-owned renderer behind the
high-level `engine/render` contract. That renderer will own GPU resource
lifetime, batching, render passes, shader/material compilation, validation,
and presentation. The Ebitengine adapter remains supported until the
engine-owned renderer reaches Wukong parity on the initial desktop and web
targets. This repository does not yet claim to provide that renderer.

Visual editor tooling, scripting, 3D rendering, mobile/consoles, networking,
navigation, and advanced animation are intentionally outside the current
runtime milestone.

## Verification

```sh
make fmt
make vet
make test
go test -race ./...
make example-build
make example-wasm
```
