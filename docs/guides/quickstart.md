# Quickstart

Requires Zig `0.15.2`. The intended first public release is `v0.1.0`, but no
tag has been published yet. `main` is not an installation source.

```sh
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
export ZIG_LOCAL_CACHE_DIR="$(mktemp -d)"
zig build test -Dwith_sdl=false
zig build browser -Dwith_sdl=false
```

These commands exercise the source checkout's headless and browser contracts.
New users should begin with [Seed Sprint](../../templates/starter/README.md):
its tiny `src/main.zig` configures the desktop host while `src/game.zig` keeps
setup in `init`, implements deterministic fixed-step simulation in `update`,
and uses Canvas in `draw`.
Its test also demonstrates a seeded replay and Canvas-command regression.

The default dependency fetches pinned SDL3 source; no system SDL installation is required. The source-checkout starter manifest deliberately contains no dependency coordinate, so it is not a usable independent project until a maintainer runs the release preparation process with a real tag and hash. The tag-release published-consumer test verifies that sequence after publication.

## Next

- [Game protocol](game-protocol.md)
- [Seed Sprint starter](../../templates/starter/README.md)
- [Core contract](core-contract.md)
- [Rendering contract](rendering.md)
- [Capability matrix](capabilities.md)
- [Release policy](releases.md)
- [Top-down proof game](../proof-games/topdown.md)
- [Puzzle proof game](../proof-games/puzzle.md)
- [Platformer proof game](../proof-games/platformer.md)
