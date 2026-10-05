# Neon Siege — Peas dogfood game

Neon Siege is a compact top-down arena game built as a real public-API
exercise. Seed Sprint remains the beginner starter; this project intentionally
uses more of Peas without importing backend or repository-internal code.

Read Neon Siege **after** Seed Sprint when you want one larger reference for
how ordinary Zig structs compose Peas features. It is not the first tutorial;
the [learning path](../../docs/index.md) introduces each subsystem before this
project combines them.

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
`zig-out/licenses/Basic-OFL.txt` notice. Its PNG, font, WAV effects, and OGG
music are embedded; it has no runtime asset directory.
`zig build web` produces a static `zig-out/web` directory and the matching
font notice under `zig-out/web/licenses`; serve it over HTTP instead of
opening `index.html` directly.

During browser iteration, replace the manual build/serve/refresh loop with:

```sh
zig build dev-web
```

It watches this project, runs the same static `web` build, serves the last
successful snapshot locally, and refreshes the page after a successful edit.
The full refresh restarts the run but retains browser save data; browser audio
may need another user interaction. Release `zig build web` output contains no
development reload client. See the [browser development guide](../../docs/guides/browser-development.md).

The checked-in manifest uses a local package-root dependency for dogfooding.
The repository's external-consumer test copies this project beside a
release-style Peas archive and substitutes the same public package dependency
shape used by release validation. Game source itself imports only
`unpolished-peas` and `unpolished-peas-sdl3`.

## Features exercised

- `GameProtocol` init/update/draw plus optional cleanup.
- Fixed-step actions for keyboard and gamepad.
- Seeded game-owned `DeterministicRng` waves.
- An authored embedded PNG decoded into a public `Image`, Atlas frames, and a
  deterministic tick-based player idle/walk animation.
- Camera world rendering into a 80x45 nearest-scaled `RenderSurface`.
- An authored embedded TrueType font for the HUD and prompts.
- Two reusable high-level WAV sound effects plus one looping incremental OGG
  background track.
- Game-owned save bytes for best score and audio preference.
- Headless replay, Canvas-trace, and pixel-hash regression tests.
- Opt-in developer diagnostics and native image/font hot reload.

## Authored assets

`embedded_assets.zig` is a small project-root wrapper around normal
`assets/neon-siege.png`, `assets/neon-siege.ttf`, and `assets/neon-loop.ogg`
files. The same public image/font/music paths run in native, headless, and
browser/Wasm builds. The compiled game does not fetch or load those files at
runtime. The music source is a repository-authored synthesized chord; its
reproducible generator is `script/generate_neon_siege_music.sh`.

The sprite sheet is repository-authored 8×8 pixel art with two player walk
frames. Its deliberate reproducible generator is
`script/generate_neon_siege_sprite_sheet.zig`; the checked-in PNG is the
runtime asset. The game advances its `SpriteAnimationPlayer` once in each
fixed update and draws the resulting ordinary Atlas frame. See the
[sprite-animation guide](../../docs/guides/sprite-animation.md) for the small
public API.

## Native developer asset reload

For a native development session, Neon Siege can replace its authored sprite
sheet and HUD font without rebuilding:

```sh
UP_DEVELOPER_TOOLS=1 \
UP_DEVELOPER_ASSET_ROOT="$PWD/assets" \
zig build run
```

The desktop wrapper registers `neon-siege.png` and `neon-siege.ttf` only while
the SDL host initializes the game. Invalid edits retain the last valid live
resource; browser builds and release packages continue using the embedded
assets and require a rebuild. See the repository's [developer asset reload
guide](../../docs/guides/developer-asset-reload.md).

## Developer diagnostics

For a compact native overlay and local diagnostics snapshot without changing
game code:

```sh
UP_DEVELOPER_TOOLS=1 zig build run
```

The [developer diagnostics guide](../../docs/guides/developer-diagnostics.md)
defines its frame, renderer, display, capability, and music fields. It is
development-only instrumentation, not gameplay state or a profiler product.
