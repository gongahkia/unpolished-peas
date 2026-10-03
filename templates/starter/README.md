# Seed Sprint — the Peas starter

Seed Sprint is a one-screen collecting game. It is deliberately small, but it
uses Peas's normal shape: `Game.init`, fixed-step `Game.update`, and
Canvas-only `Game.draw`.

## Requirements

Zig `0.15.2`. Peas fetches its pinned SDL3 source for the desktop runtime; no
system SDL installation is required.

## Run

```sh
zig build run
```

Arrow keys or a gamepad left stick/D-pad move. Space or the gamepad South
button dashes. Enter or the gamepad Start button restarts the seeded run.

## Test

```sh
zig build test
```

The test records normalized fixed-tick input, initializes two headless games
with seed `42`, and checks both gameplay state and the final logical Canvas
trace. It uses a known-empty in-memory save store, so no window, SDL video
device, GPU, or user save directory is needed.

## Package

```sh
zig build package
```

This produces the current honest desktop distribution layout:

```text
zig-out/
├── bin/seed-sprint
└── assets/
```

Run `zig-out/bin/seed-sprint` from that layout. This is not an `.app`, AppImage,
or installer; signing and platform-store distribution remain a release concern.

## Browser

Build a self-contained browser directory with:

```sh
zig build web
python3 -m http.server --directory zig-out/web 8000
```

Open `http://localhost:8000`. The standalone browser adapter and host files
are shipped by the Peas package, so copied projects use the same workflow.

## Structure

- `src/main.zig` is the desktop entry point.
- `src/game.zig` owns all game state and the `GameProtocol` callbacks.
- `src/pickup_sound.zig` contains one tiny repository-authored WAV click,
  embedded so the same audio code works on desktop and browser builds.
- `assets/` is for game-owned raw files when a project needs them.
- `build.zig` imports only the public `unpolished-peas` and
  `unpolished-peas-sdl3` package modules.

## Save data

The game keeps its best score as a four-byte little-endian value through
`ctx.save_data`. That is deliberately game-owned serialization: Peas stores
opaque bytes but does not know the score's format. Desktop persistence uses
the stable `organization` and `application` in `src/main.zig`; browser builds
use `storage_id` in `src/game.zig`. Change all three to stable game-specific
values before shipping. A failed save leaves the current session playable.

See Peas's [save-data guide](../../docs/guides/save-data.md) for key rules,
limits, and browser behavior.

## Audio

`Game.init` loads the tiny embedded pickup WAV once through `ctx.audio`; the
pickup path reuses that handle with `audio.play`. Audio output is optional, so
headless tests, missing desktop devices, and a browser awaiting its first user
gesture keep gameplay running. See the [audio guide](../../docs/guides/audio-assets.md)
for the supported high-level format and lifetime rules.

## Determinism

`Game.init` receives `GameContext.simulation_seed`, initializes its own
`DeterministicRng`, and never reads platform randomness. The replay test in
`src/game.zig` shows the intended contract: the same seed, fixed timestep,
normalized input snapshots, and deterministic game code reproduce state and
logical drawing.

Before shipping, replace `organization`, `application`, and `title` in
`src/main.zig`, plus `storage_id` in `src/game.zig`, with stable game-specific
values.

The checked-in manifest is an explicitly unreleased release template. The
release preparation step writes the immutable tag URL and matching Zig package
hash before a maintainer tags a release. Do not use `main` as a dependency.
