# v0.1 core contract

This is the pre-release v0.1 public contract. It is checked by `zig build test-core-api`; a declaration addition or removal in a listed module fails that snapshot until the change is reviewed here and in the release policy.

The root package exposes only the six named capability namespaces below. Direct root aliases are removed; import `unpolished-peas` and qualify every retained declaration through its namespace. `src/core_api_snapshot.zig` is the exact declaration-name snapshot enforced by `zig build test-core-api`.

## Modules and types

| Namespace | Frozen declarations | Contract |
| --- | --- | --- |
| `core` | `App`, `StepClock`, `GameContext`, `GameProtocol`, `GamePhase`, `GameFailure`, `DeterministicRng`, `SaveStore`, `Color`, `Vec2`, `Rect` | callback lifecycle, timing, deterministic random state, small opaque save blobs, errors, and basic 2D values |
| `input` | `Input`, `Key`, `Pointer`, `PointerButton`, `Gamepad`, `GamepadButton`, `GamepadAxis`, `Action`, `ActionBinding`, `ActionMap`, `InspectorInputPanel` | normalized keyboard, pointer, gamepad, and action state |
| `graphics` | drawing (`Canvas`, `Sprite`, batches, render commands), materials, post effects, particles, presentation, camera, diagnostics, profiler, inspector, and text-layout declarations | deterministic 2D drawing, text, post effects, particles, presentation, camera, and inspection |
| `assets` | asset store, image/font/audio handles and options, mixer/music/PCM-stream declarations, atlas/animation, reload, and sprite-sampling declarations | raw image, font, atlas, audio loading, and playback/mixing |
| `preview.developer` | `InputReplay`, `InputReplayButton`, `InputReplayRecorder`, `parseInputReplay` | replay hooks for local pre-release investigation |
| `testSupport` | `TempProject`, `Clock`, `InMemorySaveStore`, `HeadlessFrame`, `HeadlessCapture`, `CanvasTrace`, `expectCanvasTraceEqual`, `HeadlessGameRunner`, `Buttons`, `applyTopDownButtons`, `frameSeconds`, `StateHash`, `GoldenOptions`, `RendererCaptureTolerance`, `cross_backend_renderer_tolerance`, `expectRendererCapturesMatch`, `RendererConformance`, `canvasHash`, `assertGolden`, `assertReplayHash`, `expectError` | deterministic headless, replay, save-store, and golden-test hooks |

`unpolished-peas-sdl3` is the desktop adapter, not a core-game import. `unpolished-peas-wasm-core` is the Wasm build of the core namespace. `unpolished-peas-tools` and `zig build peas -- package <target>` provide packaging hooks; `--package web` emits the static browser bundle. Browser renderer availability is governed by the [capability matrix](capabilities.md), not by a game-side browser API.

Use `up.core.Color`, `up.input.Input`, `up.graphics.Canvas`, `up.assets.AssetStore`, `up.preview.developer.InputReplay`, and `up.testSupport.TempProject`; these are the only root namespaces.

## Lifecycle and errors

`GameProtocol(Game)` owns callback order and borrows the game value. A game supplies `init`, fixed-step `update`, and `draw`; `GameContext` borrows the current `Input` and, in a runtime host, exposes checked canvas and optional `SaveStore` capabilities. It may also carry an explicit optional `simulation_seed` for initialization. The desktop adapter owns asset, audio, presentation, and native save location handling. `init` runs once, `update` rejects calls before initialization and non-finite or negative elapsed time, and `draw` rejects calls before initialization or interpolation outside `0...1`.

Callback failures return their original error and are retained as `GameFailure` with the `init`, `update`, or `draw` phase. Hosts clamp elapsed wall time to five fixed steps, run fixed `update` calls before one `draw`, and expose the remaining interpolation fraction through `alpha`. Desktop reads its step rate from `sdl.Config.fixed_hz`; browser uses 60 Hz. Paused frames run no updates with zero alpha, retaining the accumulator remainder; browser visibility pauses discard hidden elapsed time on resume.

Owned values such as `Canvas`, `Image`, `Atlas`, `Font`, `Sound`, and `AssetStore` require their documented `deinit` call. Validation and loading failures return errors; the contract does not convert them to successful fallback assets.

## Rendering, input, assets, and determinism

`Canvas` provides deterministic 2D primitives, sprites, atlas frames, and built-in text; advanced materials, post effects, and GPU particles use their separate renderer path. `Camera2D` is a position, zoom, and rotation transform; games own follow, shake, cuts, and multi-camera behavior. The [stable 2D render contract](rendering.md) and [Advanced 2D](advanced-2d.md) guides define ordering, clip/blend state, transform, effects, particles, tolerance, fixture, and diagnostics rules. [Stable image assets](image-assets.md) define source formats, limits, decoded pixels, and failures. [Save data](save-data.md) keeps small opaque game blobs out of the general filesystem API. `Presentation` maps the logical canvas using `stretch`, `fit`, or `integer_fit`; pointer canvas coordinates are null outside a letterboxed destination. `HeadlessGameRunner(Game)` runs scripted `HeadlessFrame` values against `GameProtocol`, captures the canvas hash, logical Canvas trace, and submitted shared render commands. `HeadlessRenderer` consumes the same commands for deterministic captures, while `testSupport` provides replay hashing, Canvas-trace comparison, renderer-capture comparison, save-store injection, and golden diagnostics.

[`Input`](input.md) reports held, pressed, and released keyboard and pointer state per frame. `ActionMap` layers named actions over those normalized values. [Stable audio assets](audio-assets.md) define WAV sound loading, play/stop controls, browser activation, and recoverable failures. Assets remain raw files: image, font, audio, and programmatic atlas declarations have no engine-owned content schema.

## Exclusions and compatibility

The contract excludes extension ecosystems, ECS, immediate-mode UI, networking and hosted services, Box2D physics, lighting, public GPU-resource handles, meshes, compute, tile maps, tile colliders, character controllers, collision geometry, and broadphase APIs. Staged 2D materials execute through SDL GPU, WebGL 2, and WebGPU; desktop releases consume AOT artifacts and browsers compile their target source. Canvas remains the deterministic headless reference rather than an arbitrary-shader fallback. See [Advanced 2D](advanced-2d.md) and [v0.1 migrations](migrations.md) for limits and migration guidance.

For a published v0.1 release, removing or renaming a listed declaration, changing callback/error/timing behavior, or changing a supported target is a breaking change. The complete semver policy is in [releases and support](releases.md).

## Runnable reference

Run the [minimal callback example](../../examples/minimal.zig) with `zig build run-minimal`.
