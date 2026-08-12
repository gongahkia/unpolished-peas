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
| `engine` | application lifecycle, input, cameras, command layers, plugins |
| `engine/ecs` | entities, components, resources, and ordered schedules |
| `engine/scene` | ECS-backed parent/child transform hierarchy |
| `engine/assets` | typed asset handles, reload hooks, async loading, manifests |
| `engine/audio` | backend-neutral playback and bus mixing |
| `engine/physics` | deterministic AABB 2D bodies, contacts, and queries |
| `engine/ui` | retained layout, focus, and pointer hit testing |
| `engine/render` | backend-neutral high-level 2D commands and portable texture sources |
| `engine/platform` | engine-owned Linux X11, Win32, AppKit/CAMetalLayer, and browser canvas hosts |
| `engine/diagnostics` | counters and duration summaries |

## Documentation

Start with the engine documentation, not the example source:

- [public API stability and compatibility policy](docs/PUBLIC_API.md)
- [architecture and ownership](docs/ARCHITECTURE.md)
- [contributor workflow](CONTRIBUTING.md)
- [host and renderer development](docs/BACKEND_DEVELOPMENT.md)
- [deterministic render testing](docs/RENDER_TESTING.md)
- [structured runtime failures](docs/ERRORS.md)
- [performance baseline and GPU-validation process](docs/PERFORMANCE.md)
- [platform build and runtime evidence matrix](docs/SUPPORT.md)
- [v0.1 release dry-run and evidence requirements](docs/RELEASING.md)
- [current product and engineering readiness audit](docs/READINESS.md)
- [architecture decision record process](docs/adr/README.md)
- [renderer architecture decision](docs/adr/0001-webgpu-renderer-boundary.md)
- [WebGPU dependency decision](docs/adr/0002-webgpu-dependency-decision.md)
- [2D physics boundary](docs/PHYSICS.md)
- [portable asset loaders](docs/ASSETS.md)
- [project asset packaging](docs/ASSET_PACKAGING.md)
- [platform host contract](docs/HOSTS.md)
- [portable input and rebinding](docs/INPUT.md)
- [audio playback and device policy](docs/AUDIO.md)
- [first game tutorial](docs/FIRST_GAME.md)
- [Wukong example](example/wukong), an optional game built with the public API

## Wukong example

[Wukong](example/wukong) is optional example-game source, not engine API or a
definition of engine policy. It owns its deterministic procedural platforming
simulation, assets, replay tooling, and playtest rules; it demonstrates the
kind of game a 72 user can write.

```sh
make example-run
```

## Renderer transition

`engine/platform` owns the Linux X11 and browser hosts. Its private WebGPU
renderer consumes the high-level `engine/render` command frame, owns GPU
resources, batching, render passes, shader validation, and presentation, and
does not expose graphics-binding handles to game code. [ADR 0003](docs/adr/0003-engine-owned-webgpu-renderer.md)
records the dependency and ownership decision.

The Linux X11 path has local creation, deterministic software-WebGPU image,
and five-second example smoke results. The browser path has a local Chromium
render/input/resize/focus/visibility result and a rendered-frame smoke test.
Windows and macOS now have native host implementations, but remain compile-only
until they have runtime evidence; browser support beyond that one local
Chromium environment is likewise unverified. Source targets distinguish
buildability from runtime support. There is no Canvas or WebGL fallback when
WebGPU is unavailable.

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
