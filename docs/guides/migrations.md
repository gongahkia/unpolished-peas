# v0.1 migrations

## Engine-owned extensions removed

v0.1 removes the engine-owned extension manifest, resolver, lock, test matrix, and CI gates. Delete those engine-specific files from a game or integration. Third-party Zig dependencies remain game-owned: declare and resolve them directly in the game's `build.zig.zon` and `build.zig`.

## Particle emitters removed

v0.1 removes the engine-owned particle emitter runtime and public API. Delete particle-emitter calls and keep any game-specific visual simulation in game code.

## ECS removed

v0.1 removes the engine-owned ECS and its public API. Delete ECS world, entity, component-store, and command usage; keep game-owned data structures in game code.

## Immediate-mode UI removed

v0.1 removes the engine-owned immediate-mode UI subsystem and public API. Delete its frame, widget, layout, and state calls; keep game-specific HUD rendering in game code.

## Networking and services excluded

Networking, relays, and hosted services were not shipped in this checkout and are not v0.1 core capabilities. Keep any such integration game-owned.

## Box2D physics removed

v0.1 removes the engine-owned Box2D physics subsystem and its public API. Keep physics simulation and collision behavior game-owned.

## Effects, shader assets, lighting, and GPU resources removed

v0.1 removes engine-owned effects, post-processing, shader assets, lighting, and public GPU-resource handles. Keep game-specific rendering extensions and resource ownership in game code; core rendering remains limited to documented 2D primitives, sprites, text, and presentation.

## Tile maps and collision systems removed

v0.1 removes engine-owned tile maps, tile colliders, character controllers, collision geometry, and broadphase APIs. Keep map formats, collision logic, and movement rules game-owned; `Rect` and `Vec2` remain available for 2D rendering.
