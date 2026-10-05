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

`zig build package` produces `zig-out/bin/neon-siege` and the embedded font's
`zig-out/licenses/Basic-OFL.txt` notice. It has no runtime asset directory.
`zig build web` produces a static `zig-out/web` directory and the matching
font notice under `zig-out/web/licenses`; serve it over HTTP instead of
opening `index.html` directly.

The checked-in manifest uses a local package-root dependency for dogfooding.
The repository's external-consumer test copies this project beside a
release-style Peas archive and substitutes the same public package dependency
shape used by release validation. Game source itself imports only
`unpolished-peas` and `unpolished-peas-sdl3`.

## Features exercised

- `GameProtocol` init/update/draw plus optional cleanup.
- Fixed-step actions for keyboard and gamepad.
- Seeded game-owned `DeterministicRng` waves.
- An authored embedded PNG decoded into a public `Image` and Atlas frames.
- Camera world rendering into a 80x45 nearest-scaled `RenderSurface`.
- An authored embedded TrueType font for the HUD and prompts.
- Two reusable high-level WAV sound effects.
- Game-owned save bytes for best score and audio preference.
- Headless replay, Canvas-trace, and pixel-hash regression tests.

## Authored assets

`embedded_assets.zig` is a small project-root wrapper around normal
`assets/neon-siege.png` and `assets/neon-siege.ttf` files. The same public
`Image.decode` and `Font.decodeTrueType` calls run in native, headless, and
browser/Wasm builds. Decoded resources are owned by `Game` and released from
its protocol `deinit`; the compiled game does not fetch or load those files at
runtime.
