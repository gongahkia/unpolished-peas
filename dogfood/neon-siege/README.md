# Neon Siege — Peas dogfood game

Neon Siege is a compact top-down arena game built as a real public-API
exercise. Seed Sprint remains the beginner starter; this project intentionally
uses more of Peas without importing backend or repository-internal code.

## Controls

- Arrow keys, D-pad, or left stick: move and aim.
- Space or gamepad South: shoot.
- X or gamepad East: dash.
- Enter or gamepad Start: restart after a breach.
- Tab or gamepad Back: toggle audio output for this run and future launches.

## From this checkout

```sh
cd dogfood/neon-siege
zig build
zig build run
zig build test
zig build package
zig build web
python3 -m http.server --directory zig-out/web 8000
```

`zig build package` produces `zig-out/bin/neon-siege` plus `zig-out/assets`.
`zig build web` produces a static `zig-out/web` directory; serve it over HTTP
instead of opening `index.html` directly.

The checked-in manifest uses a local package-root dependency for dogfooding.
The repository's external-consumer test copies this project beside a
release-style Peas archive and substitutes the same public package dependency
shape used by release validation. Game source itself imports only
`unpolished-peas` and `unpolished-peas-sdl3`.

## Features exercised

- `GameProtocol` init/update/draw plus optional cleanup.
- Fixed-step actions for keyboard and gamepad.
- Seeded game-owned `DeterministicRng` waves.
- Generated public Image and Atlas frames (with a native TGA decode proof).
- Camera world rendering into a 80x45 nearest-scaled `RenderSurface`.
- Built-in Canvas text HUD.
- Two reusable high-level WAV sound effects.
- Game-owned save bytes for best score and audio preference.
- Headless replay, Canvas-trace, and pixel-hash regression tests.

## Deliberate limitations

The tiny authored assets are source byte arrays so the reference remains
self-contained. The game builds an `Image` from generated pixels on both
targets because Peas's stb-backed `Image.decode` path is currently native-only.
That is a useful portability proof, not a replacement for a polished external
image/font asset workflow; the dogfood friction log records that distinction.
