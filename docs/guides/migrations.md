# v0.1 migrations

## Engine-owned extensions removed

v0.1 removes the engine-owned extension manifest, resolver, lock, test matrix, and CI gates. Delete those engine-specific files from a game or integration. Third-party Zig dependencies remain game-owned: declare and resolve them directly in the game's `build.zig.zon` and `build.zig`.

## Particle emitters removed

v0.1 removes the engine-owned particle emitter runtime and public API. Delete particle-emitter calls and keep any game-specific visual simulation in game code.
