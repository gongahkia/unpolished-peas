# unpolished-peas

<div align="center">
    <img src="./asset/logo/peas-color-logo.png" width="30%">
</div>

Small Zig 2D engine experiment.

## API Goal

unpolished-peas should feel as simple to start with as raylib, LÖVE, and Ebitengine:

- draw a sprite, play a sound, read input, and reload an asset with minimal setup.
- keep tiny games in one readable file without framework ceremony.
- make the simple path obvious, while preserving explicit Zig control flow.
- treat long examples as temporary scaffolding until the public API supports shorter ones.

## Requirements

- Zig 0.15.2 exactly
- no system SDL3 installation in the default pinned-source mode

```sh
zig build test-sdl
```

`zig build test-sdl` uses the pinned SDL3 source in `build.zig.zon`. The pinned Box2D source is reserved for the optional physics module and is validated with `zig build test-box2d`.

The `unpolished-peas` core module has no SDL3 dependency. Import `unpolished-peas-sdl3` separately only for the desktop runtime.

To use a system SDL3 instead:

```sh
brew install sdl3 pkg-config
zig build -Dsystem-sdl=true run-bounce-sdl
```

On Debian or Ubuntu, replace the `brew install` command with `sudo apt install libsdl3-dev pkg-config`.

## Tiny Start

```zig
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.rect(18, 18, 28, 28, up.Color.rgb(255, 198, 74));
        ctx.text("HELLO", 8, 8, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.play(.{ .width = 80, .height = 60, .scale = 6 }, Game);
}
```

## Starter Project

From an unpolished-peas checkout:

```sh
zig build new -- ../my-game
cd ../my-game
zig build run
```

The generated bouncing-square game includes its own build files and points to the engine checkout that created it. The GitHub remote currently has no commit that Zig can fingerprint, so the generator cannot yet write a pinned Git dependency. Replace this local path dependency after the first published unpolished-peas release.

## Positioning

- Not blank space: Mach, zig-gamedev, jok, Delve, and several small engines exist.
- Gap: no obvious widely adopted Zig equivalent of LÖVE/raylib/Ebitengine with a 2D-first API and tiny first-win path.
- Bet: win by being the fastest path from `zig build run` to a visible 2D game, with headless tests and explicit control flow.
- Non-goal: compete with Mach on broad WebGPU/full-engine scope or with zig-gamedev as a toolbox.

## Differentiators

- 2D-only first; no editor and no 3D surface until the 2D loop is excellent.
- Headless renderer for CI screenshots, examples, and deterministic tests.
- Reloadable file assets via polling `mtime`, so iteration works before native file watchers.
- Built-in debug text with no font dependency.
- Public API stays explicit: user code owns update/render order.

## Commands

```sh
zig build test
zig build run-bounce
zig build run-bounce-sdl
zig build dev-bounce
zig build run-minimal
zig build run-audio
zig build run-atlas
zig build run-camera
zig build run-tilemap
zig build test-scenes
zig build stress-audio-sdl
zig build new -- ../my-game
zig build upmapc -- level.upmap level.upmapb
```

`run-bounce` renders `zig-out/bounce.ppm`.
`run-bounce-sdl` opens an SDL3 window.
`dev-bounce` opens a PNG/text live-reload demo.
`run-audio` opens a WAV/OGG audio demo.
`run-atlas` opens a JSON atlas/tile scene demo.
`run-camera` opens the resizable multi-viewport camera demo.
`run-tilemap` opens the sparse tile-map and camera-culling demo.
`test-scenes` runs deterministic headless scene hashing.
`stress-audio-sdl` runs a local SDL audio stress smoke.
`new` creates the bouncing-square starter project.

## Developer Runtime

`Config.developer_tools` defaults to enabled in Debug builds. F3 toggles the FPS/frame-time overlay. F12 writes a PPM screenshot. The app-data path is printed at startup, available through `Context.appDataPath`, and contains `unpolished-peas.log` when developer tools are enabled.

Game initialization, update, draw, and asset-reload errors are written to the terminal and log, then held in an in-window error state until Escape is pressed. Zig panics remain process failures and require the normal debugger/test workflow.

## Camera And Presentation

`Camera2D` provides position, zoom limits, rotation, viewport rectangles, world bounds, nearest or bilinear image sampling, pixel snapping, dead-zone follow, spring motion, deterministic shake, coordinate conversion, visibility checks, and parallax copies. `CameraRig` owns an arbitrary number of generation-checked cameras; `CameraDirector` plays deterministic cuts and blended shots.

Use `ctx.camera(&camera)` for world rendering. It transforms and clips rectangles, circles, lines, images, atlas frames, and text to the camera viewport. Use the existing `ctx` drawing calls for HUD rendering.

SDL windows support `Config.resizable` and `.stretch`, `.fit`, or `.integer_fit` presentation. `Input.pointer` exposes window, physical framebuffer, and optional logical-canvas coordinates; letterbox bars map to `null` canvas coordinates.

## Current API

- `Vec2`, `Rect`
- `Color`
- `Input`, `Key`
- `Pointer`, `PointerButton`
- `StepClock`
- `Canvas`, `Sprite`
- `Canvas.drawImage`
- `Canvas.drawAtlasFrame`
- `Canvas.drawText`
- `Camera2D`, `CameraCanvas`, `CameraRig`, `CameraDirector`
- `TileMap`, `TileMapLayer`, `TileSet`, `TileMapHandle`
- `TileMap.loadNative`, `TileMap.loadTiled`, `TileMap.loadLdtkProject`
- `upmapc` native JSON-to-binary compiler
- `Presentation`, `PresentationMode`
- `AssetFile`
- `AssetStore`
- `Image`
- `Atlas`
- `AtlasFrameHandle`
- `AnimationPlayer`
- `Sound`
- `Music`
- `AudioMixer`
- `BusHandle`
- `PlaybackHandle`
- `unpolished-peas-sdl3.play`, `unpolished-peas-sdl3.Context`
- `unpolished-peas-sdl3.run` for lower-level control
- `unpolished-peas-sdl3.appDataPath`

## Next Build Targets

1. Publish a tagged package release and update `zig build new` to generate a pinned Git dependency.
2. Complete external tile-source blitting and compressed/external Tiled fixture coverage for the tile-map compatibility layer.
3. Add explicit 2D collision queries and resolution for rectangles, circles, and tile maps; ship a character-controller example.
4. Add an optional Box2D-backed physics module with explicit world stepping, body/fixture lifetime, and deterministic headless tests; do not hand-roll a general rigid-body solver.
5. Add an opt-in ECS with generation-checked entities, sparse component stores, deterministic queries, and no hidden scheduler; keep direct struct-based games first-class.
6. Add gamepad support plus named action mapping, rebinding, and deterministic input tests.
7. Add a shader API with one strict pixel-effect example and headless fallback coverage.
8. Add project packaging, desktop release artifacts, and web export after desktop assets, audio, camera, and input are stable.
