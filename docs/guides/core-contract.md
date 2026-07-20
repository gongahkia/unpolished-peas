# v0.1 core contract

This is the pre-release v0.1 public contract. It is checked by `zig build test-core-api`; a declaration addition or removal in a listed module fails that snapshot until the change is reviewed here and in the release policy.

The root package exposes only the six named capability namespaces below. Direct root aliases are removed; import `unpolished-peas` and qualify every retained declaration through its namespace. `src/core_api_snapshot.zig` is the exact declaration-name snapshot enforced by `zig build test-core-api`.

## Modules and types

| Namespace | Frozen declarations | Contract |
| --- | --- | --- |
| `core` | `App`, `StepClock`, `GameContext`, `GameProtocol`, `GamePhase`, `GameFailure`, `Color`, `Vec2`, `Rect` | callback lifecycle, timing, errors, and basic 2D values |
| `input` | `Input`, `Key`, `Pointer`, `PointerButton`, `Gamepad`, `GamepadButton`, `GamepadAxis`, `Action`, `ActionBinding`, `ActionMap`, `InspectorInputPanel` | normalized keyboard, pointer, gamepad, and action state |
| `graphics` | drawing (`Canvas`, `Sprite`, batches, render commands), presentation, camera, diagnostics, profiler, inspector, and text-layout declarations | deterministic 2D drawing, text, presentation, camera, and inspection |
| `assets` | asset store, image/font/audio handles and options, atlas/animation, reload, and sprite-sampling declarations | raw image, font, atlas, and audio loading |
| `preview.developer` | `InputReplay`, `InputReplayButton`, `InputReplayRecorder`, `parseInputReplay` | replay hooks for local pre-release investigation |
| `testSupport` | `TempProject`, `Clock`, `Buttons`, `applyTopDownButtons`, `frameSeconds`, `StateHash`, `GoldenOptions`, `RendererCaptureTolerance`, `cross_backend_renderer_tolerance`, `expectRendererCapturesMatch`, `RendererConformance`, `canvasHash`, `assertGolden`, `assertReplayHash`, `expectError` | deterministic headless, replay, and golden-test hooks |

`unpolished-peas-sdl3` is the desktop adapter, not a core-game import. `unpolished-peas-wasm-core` is the Wasm build of the core namespace. `unpolished-peas-tools` and `zig build peas -- package <target>` provide packaging hooks; `--package web` emits the static browser bundle. Browser renderer availability is governed by the [capability matrix](capabilities.md), not by a game-side browser API.

Use `up.core.Color`, `up.input.Input`, `up.graphics.Canvas`, `up.assets.AssetStore`, `up.preview.developer.InputReplay`, and `up.testSupport.TempProject`; these are the only root namespaces.

## Lifecycle and errors

`GameProtocol(Game)` owns callback order and borrows the game value. A game supplies `init`, fixed-step `update`, and `draw`; `GameContext` borrows the current `Input` and, in a runtime host, exposes a checked core canvas capability. The desktop adapter owns asset, audio, and presentation handling. `init` runs once, `update` rejects calls before initialization and non-finite or negative elapsed time, and `draw` rejects calls before initialization or interpolation outside `0...1`.

Callback failures return their original error and are retained as `GameFailure` with the `init`, `update`, or `draw` phase. `StepClock` clamps a frame delta to its fixed-step budget and exposes the remaining interpolation fraction through `alpha`.

Owned values such as `Canvas`, `Image`, `Atlas`, `Font`, `Sound`, `Music`, and `AssetStore` require their documented `deinit` call. Validation and loading failures return errors; the contract does not convert them to successful fallback assets.

## Rendering, input, assets, and determinism

`Canvas` records deterministic 2D primitives, sprites, atlas frames, and built-in text. `Camera2D` is a position-and-zoom transform; games own follow, shake, cuts, and multi-camera behavior. `Presentation` maps the logical canvas using `stretch`, `fit`, or `integer_fit`; pointer canvas coordinates are null outside a letterboxed destination. `HeadlessRenderer` consumes the same commands for deterministic captures, while `testSupport` provides replay hashing, renderer-capture comparison, and golden diagnostics.

`Input` reports held, pressed, and released keyboard and pointer state per frame. `ActionMap` layers named actions over those normalized values. Audio is game-owned data loaded as `Sound` or `Music` and played through the runtime adapter; the core preserves bounded decoding and error returns. Assets remain raw files: image, font, audio, and programmatic atlas declarations have no engine-owned content schema.

## Exclusions and compatibility

The contract excludes extension ecosystems, particles, ECS, immediate-mode UI, networking and hosted services, Box2D physics, effects, shader assets, lighting, public GPU-resource handles, tile maps, tile colliders, character controllers, collision geometry, and broadphase APIs. See [v0.1 migrations](migrations.md) for removal guidance.

For a published v0.1 release, removing or renaming a listed declaration, changing callback/error/timing behavior, or changing a supported target is a breaking change. The complete semver policy is in [releases and support](releases.md).

## Runnable reference

Run the [minimal callback example](../../examples/minimal.zig) with `zig build run-minimal`.
