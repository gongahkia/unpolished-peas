# v0.1 migrations

## Root aliases removed

v0.1 exposes only `core`, `input`, `graphics`, `assets`, `preview`, and `testSupport` from `@import("unpolished-peas")`. Qualify retained names through those namespaces: `up.Color` becomes `up.core.Color`, `up.Canvas` becomes `up.graphics.Canvas`, `up.AssetStore` becomes `up.assets.AssetStore`, and `up.Input` becomes `up.input.Input`. Replay hooks move under `up.preview.developer`.

## Engine-owned extensions removed

v0.1 removes the engine-owned extension manifest, resolver, lock, test matrix, and CI gates. Delete those engine-specific files from a game or integration. Third-party Zig dependencies remain game-owned: declare and resolve them directly in the game's `build.zig.zon` and `build.zig`.

## Particle emitters

v0.1 includes `graphics.ParticleSystem` for deterministic CPU simulation and reference `Canvas` drawing. It is appropriate for bounded 2D effects whose spawn, lifetime, velocity, gravity, size, and colour interpolation belong in the game configuration. It is not an ECS, scene, collision, or GPU-compute system; preserve game-owned simulation that needs those concerns. Call `submit` with `GameContext.requireRenderer2D()` to render quads through the SDL GPU or browser instanced presenter. The OpenGL preview presenter rejects advanced queues; use `draw` when deterministic Canvas output is the required fallback.

## ECS removed

v0.1 removes the engine-owned ECS and its public API. Delete ECS world, entity, component-store, and command usage; keep game-owned data structures in game code.

## Immediate-mode UI removed

v0.1 removes the engine-owned immediate-mode UI subsystem and public API. Delete its frame, widget, layout, and state calls; keep game-specific HUD rendering in game code.

## Networking and services excluded

Networking, relays, and hosted services were not shipped in this checkout and are not v0.1 core capabilities. Keep any such integration game-owned.

## Box2D physics removed

v0.1 removes the engine-owned Box2D physics subsystem and its public API. Keep physics simulation and collision behavior game-owned.

## Effects, shader assets, lighting, and GPU resources

v0.1 includes staged executable 2D materials and final-composited GPU post passes. Migrate validation-only `ShaderSourceBundle` uses to `AssetStore.loadMaterial` and `Material.initStages`; build AOT SPIR-V, DXBC, and metallib artifacts with `peas shader`, then keep GLSL ES and WGSL source beside them for browsers. Named image and std140 uniform bindings replace an unstructured uniform payload. The small CPU-reference post-effect chain (`tint`, `grayscale`, `pixelate`, `blur`, and `crt`) remains useful for headless Canvas behavior. Lighting, public GPU-resource handles, meshes, compute, and arbitrary non-2D rendering remain excluded.

## Tile maps and collision systems removed

v0.1 removes engine-owned tile maps, tile colliders, character controllers, collision geometry, and broadphase APIs. Keep map formats, collision logic, and movement rules game-owned; `Rect` and `Vec2` remain available for 2D rendering.
