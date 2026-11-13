# v1.0 migrations

## Root aliases removed

v1.0 exposes only `core`, `input`, `graphics`, `assets`, `preview`, and `testSupport` from `@import("unpolished-peas")`. Qualify retained names through those namespaces: `up.Color` becomes `up.core.Color`, `up.Canvas` becomes `up.graphics.Canvas`, `up.AssetStore` becomes `up.assets.AssetStore`, and `up.Input` becomes `up.input.Input`. Replay hooks move under `up.preview.developer`.

## Engine-owned extensions removed

v1.0 removes the engine-owned extension manifest, resolver, lock, test matrix, and CI gates. Delete those engine-specific files from a game or integration. Third-party Zig dependencies remain game-owned: declare and resolve them directly in the game's `build.zig.zon` and `build.zig`.

## Particle emitters

v1.0 includes `graphics.ParticleSystem` for deterministic CPU simulation and reference `Canvas` drawing. It is appropriate for bounded 2D effects whose spawn, lifetime, velocity, gravity, size, and colour interpolation belong in the game configuration. It is not an ECS, scene, collision, or GPU-compute system; preserve game-owned simulation that needs those concerns. Call `submit` with `GameContext.requireRenderer2D()` to render quads through the SDL GPU or browser instanced presenter. The OpenGL preview presenter rejects advanced queues; use `draw` when deterministic Canvas output is the required fallback.

## ECS removed

v1.0 removes the engine-owned ECS and its public API. Delete ECS world, entity, component-store, and command usage; keep game-owned data structures in game code.

## Immediate-mode UI removed

v1.0 removes the engine-owned immediate-mode UI subsystem and public API. Delete its frame, widget, layout, and state calls; keep game-specific HUD rendering in game code.

## Networking and services excluded

Networking, relays, and hosted services were not shipped in this checkout and are not v1.0 core capabilities. Keep any such integration game-owned.

## Box2D physics removed

v1.0 removes the engine-owned Box2D physics subsystem and its public API. Keep physics simulation and collision behavior game-owned.

## Effects, shader assets, lighting, and GPU resources

v1.0 includes staged executable 2D materials and final-composited GPU post passes. Migrate validation-only `ShaderSourceBundle` uses to `AssetStore.loadMaterial` and `Material.initStages`; build AOT SPIR-V, DXBC, and metallib artifacts with `peas shader`, then keep GLSL ES and WGSL source beside them for browsers. Named image and std140 uniform bindings replace an unstructured uniform payload. The small CPU-reference post-effect chain (`tint`, `grayscale`, `pixelate`, `blur`, and `crt`) remains useful for headless Canvas behavior. Lighting, public GPU-resource handles, meshes, compute, and arbitrary non-2D rendering remain excluded.

## Tile maps and collision systems removed

v1.0 removes engine-owned tile maps, tile colliders, character controllers, collision geometry, and broadphase APIs. Keep map formats, collision logic, and movement rules game-owned; `Rect` and `Vec2` remain available for 2D rendering.


## Physical keyboard and text extension

Existing normalized keys, `GameProtocol` callbacks, root namespaces and old
replay formats are retained. New game code can opt into `Input.PhysicalKey`,
`ActionBinding.physical_key`, `Input.extended`, and `ctx.setTextInput`.
Exhaustive application switches over `ActionBinding` must add the new union
case. Native filesystem persistence remains optional; browser rebinding works
in memory without importing filesystem APIs. Do not serialize `Input` struct
memory: use the versioned replay or browser input codec.

UPR5 is selected only when extension data is present. UPR1–UPR4 input decodes
with an empty extension, and normalized-only encoders preserve previous bytes
and hashes. Browser input v2 is negotiated through buffer capacity while the
376-byte v1 layout and host import names stay available. An older v1 browser
host can still supply normalized input to the new runtime, but cannot supply
physical/text capabilities; `extended.active` remains false for unsupported
text requests. See [input compatibility](input-v2-compatibility.md).

## Optional embedded asset collection

`assets.AssetCollection` and `assets.Atlas.decode` are additive. Existing
Image/Font/Atlas/AssetStore APIs remain available. To group related embedded
assets, keep one collection in game state, load through its image/font/atlas
methods, and replace individual resource cleanup with collection cleanup.
Returned pointers borrow that collection and must not be freed separately.
Drawing and deterministic sprite-animation APIs do not change. Audio handles
remain host-owned. See [compiled asset recipes](asset-recipes.md).

The generated desktop wrapper now forwards an optional game `deinit`. Older
projects adding owned assets must add that forwarding callback as shown in the
[asset workbench entry point](../../examples/asset_workbench.zig).

## Portable workflow integration fixes

The browser runtime accepts module-level `storage_id` as used by generated
starters and reference games. An existing `Game.storage_id` retains precedence;
no saved-key prefix changes for games already using it. Browser init/shutdown
now forward game cleanup before releasing host capabilities and cancel prior
frame callbacks before retrying initialization.

Owned ActionMaps now honor digital edges retained in a fixed-tick snapshot even
when a complete tap leaves the final held value at zero. Replay formats are
unchanged; previously ignored recorded taps can now trigger their intended
action. Existing golden assertions are retained. See
[portable workflow verification](portable-conformance.md).
