# Lantern Leap — second Peas reference game

Lantern Leap is a small deterministic side-scrolling platformer. It is the
second public-API reference game: Seed Sprint is the beginner project, Neon
Siege is the arena/action reference, and this project exercises scrolling,
platform collision, checkpoints, and sprite animation without treating them
as engine subsystems.

Read it after the [learning path](../../docs/index.md) introduces the core
concepts. The game owns gravity, AABB collision, level rectangles, coyote
time, checkpoint rules, and animation-state selection in ordinary Zig.

## Controls

- Arrow keys, D-pad, or left stick: move.
- Space or gamepad South: jump.
- Enter or gamepad Start: restart the run (or respawn immediately after a
  death).

## From this checkout

```sh
cd dogfood/lantern-leap
zig build
zig build run
zig build test
zig build package
zig build web
python3 -m http.server --directory zig-out/web 8000
```

For browser iteration, use the supported full-rebuild development workflow:

```sh
zig build dev-web
```

It watches the project, rebuilds the same static browser package, serves the
last successful result, and full-refreshes after successful edits. Browser
save data survives a refresh; browser audio may require user interaction
again. `zig build web` remains a static production output with no watch or
reload client.

`zig build package` installs `zig-out/bin/lantern-leap` plus the Basic font
notice under `zig-out/licenses`. The authored PNG, TTF, generated WAV effects,
and OGG loop are embedded, so release packages have no runtime asset folder.

## Features demonstrated

- Public `GameProtocol` lifecycle, owned allocator resources, and `deinit`.
- Fixed-step keyboard/gamepad `ActionMap` input and game-owned coyote time.
- Hand-authored static AABB level collision and a clamped `Camera2D` follow
  policy—no physics, tilemap, or scene system.
- Embedded PNG → `Image` → `Atlas`, plus public deterministic
  `SpriteAnimationPlayer` idle/run/jump clips.
- A 80×45 CPU `RenderSurface` nearest-scaled to the 160×90 Canvas.
- Embedded TrueType HUD text, reusable WAV SFX, and incrementally decoded
  looping OGG music.
- Game-owned `SaveStore` progress bytes, checkpoints, headless replay,
  Canvas-trace, and pixel-hash comparison tests.
- Opt-in native developer diagnostics and image/font hot reload registration.

## Authored assets

`embedded_assets.zig` embeds ordinary files from `assets/` for native,
headless, and browser/Wasm builds. The 8×8 pixel sprite sheet is
repository-authored; `script/generate_lantern_leap_sprite_sheet.zig` records
its reproducible source. `script/generate_lantern_leap_music.sh` produces the
short synthesized Vorbis loop from generated sine tones only. The copied Basic
font is distributed with its OFL notice in `assets/OFL.txt`.

For native development-only image/font reload:

```sh
UP_DEVELOPER_TOOLS=1 \
UP_DEVELOPER_ASSET_ROOT="$PWD/assets" \
zig build run
```

Invalid visual edits retain the old live resource. Browser and release builds
keep using embedded resources and need a rebuild.
