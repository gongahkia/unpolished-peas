# v0.1 migrations

## Engine-owned extensions removed

v0.1 removes the engine-owned extension manifest, resolver, lock, test matrix, and CI gates. Delete those engine-specific files from a game or integration. Third-party Zig dependencies remain game-owned: declare and resolve them directly in the game's `build.zig.zon` and `build.zig`.

## Particle emitters removed

v0.1 removes the engine-owned particle emitter runtime and public API. Delete particle-emitter calls and keep any game-specific visual simulation in game code.

## ECS removed

v0.1 removes the engine-owned ECS and its public API. Delete ECS world, entity, component-store, and command usage; keep game-owned data structures in game code.

## Immediate-mode UI removed

v0.1 removes the engine-owned immediate-mode UI subsystem and public API. Delete its frame, widget, layout, and state calls; keep game-specific HUD rendering in game code.
