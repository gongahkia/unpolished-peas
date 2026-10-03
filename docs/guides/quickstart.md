# Quickstart

Requires Zig `0.15.2`. There is no published tag for this v0.1 development contract: `v0.0.4` does not exist as a repository tag. `main` is not an installation source.

```sh
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
export ZIG_LOCAL_CACHE_DIR="$(mktemp -d)"
zig build test -Dwith_sdl=false
zig build browser -Dwith_sdl=false
```

These commands exercise the source checkout's headless and browser contracts.
New users should begin with [Seed Sprint](../../templates/bounce/README.md):
its `src/game.zig` configures `Game.config`, keeps setup in `init`, implements
deterministic fixed-step simulation in `update`, and uses Canvas in `draw`.
Its test also demonstrates a seeded replay and Canvas-command regression.

The default dependency fetches pinned SDL3 source; no system SDL installation is required. The generated starter manifest contains a release-time dependency coordinate, so it is not a usable independent project until a maintainer runs the release preparation process with a real tag and hash. The tag-release published-consumer test verifies that sequence after publication.

## Next

- [Game protocol](game-protocol.md)
- [Seed Sprint starter](../../templates/bounce/README.md)
- [Core contract](core-contract.md)
- [Rendering contract](rendering.md)
- [Capability matrix](capabilities.md)
- [Release policy](releases.md)
- [Top-down proof game](../proof-games/topdown.md)
- [Puzzle proof game](../proof-games/puzzle.md)
- [Platformer proof game](../proof-games/platformer.md)
