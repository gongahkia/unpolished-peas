# Quickstart

Requires Zig `0.15.2`. Use the published `v0.0.4` checkout and fresh Zig caches; `main` is not an installation source.

```sh
git clone --depth 1 --branch v0.0.4 https://github.com/gongahkia/unpolished-peas.git
cd unpolished-peas
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
export ZIG_LOCAL_CACHE_DIR="$(mktemp -d)"
zig build new -- game
cd game
zig build run -- --frames 2
```

The starter is a callback game. Edit `src/main.zig`: configure `Game.config`, put setup in `init`, deterministic simulation in fixed-step `update`, and 2D drawing in `draw`. Use [the copied starter source](../../templates/bounce/src/main.zig) as the complete small example.

The default dependency fetches pinned SDL3 source; no system SDL installation is required. The command sequence is exercised by the tag-release published-consumer test with empty global and local Zig caches.

## Next

- [Game protocol](game-protocol.md)
- [Core contract](core-contract.md)
- [Rendering contract](rendering.md)
- [Capability matrix](capabilities.md)
- [Release policy](releases.md)
- [Top-down proof game](../proof-games/topdown.md)
- [Puzzle proof game](../proof-games/puzzle.md)
- [Platformer proof game](../proof-games/platformer.md)
