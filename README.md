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

Published modules are `unpolished-peas` (core), `unpolished-peas-sdl3` (desktop runtime), `unpolished-peas-tools` (host CLI helpers), `unpolished-peas-test` (deterministic test fixtures), and `unpolished-peas-services` (SDL-free online-service contracts). Tools and services import no desktop runtime; `zig build test-modules` checks the independent core, tools, test fixtures, and services graph.

[fixtures/modules](fixtures/modules) is a downstream SDL-free import fixture for core, tools, and services.

`unpolished-peas-physics` is a separate optional Box2D module with explicit `World.init`, `step`, and `deinit`; the core module and generated starter do not link Box2D.

`Context.text` uses the built-in 5×7 debug font. `AssetStore.loadFont` loads TrueType/OpenType fonts into a GPU atlas; configure `FontLoadOptions.ranges` with one or more Unicode ranges. `Context.font` uses strict UTF-8 replacement and the configured fallback glyph, while `Font.textDiagnostics` exposes invalid UTF-8 and missing/fallback glyph counts. `loadBitmapFont` loads AngelCode text `.fnt` descriptors; `layoutText` shares the same deterministic UTF-8 decoder.

`Image.decode` and `AssetStore.loadImage` accept PNG, JPEG, and TGA with a 32 MiB input cap, 4096×4096 dimension caps, and a 16 MiB pixel cap; pass `ImageDecodeOptions` to tighten direct decoder limits.

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
    pub const config: sdl.Config = .{ .width = 80, .height = 60, .scale = 6 };

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.rect(18, 18, 28, 28, up.Color.rgb(255, 198, 74));
        ctx.text("HELLO", 8, 8, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
```

## Explicit Loop

sdl.playGame(Game) reads window, presentation, developer, asset-root, and lifecycle configuration from Game.config. sdl.play(config, Game) and sdl.run(config, state, callbacks) remain equivalent low-level paths; [examples/explicit_loop.zig](examples/explicit_loop.zig) compiles without a Game type.

Set Game.config.pause_policy to .unfocused or .minimized to suppress update callbacks while that desktop state applies. Focus, minimize, restore, resize, and close stay ordered Event callbacks; draw continues with ctx.dt set to zero, leaving game state under user control.

Set `Config.actions` to repeated `Action` entries with the same context/name to merge keyboard, mouse, and gamepad bindings. `Context.actionValue`, `actionIsDown`, `actionWasPressed`, and `actionWasReleased` read the per-frame map; `Context.rebindAction` or `Context.rebindActionBinding` persists `bindings.up` in app data.

## Starter Project

From an unpolished-peas checkout:

```sh
zig build new -- ../my-game
cd ../my-game
zig build run
```

The generated bouncing-square game includes its own build files and a pinned `unpolished-peas` v0.0.3 release archive dependency.

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
zig build test-support
zig build test-modules
zig build run-bounce
zig build run-bounce-sdl
zig build dev-bounce
zig build run-minimal
zig build run-explicit-loop
zig build run-audio
zig build run-atlas
zig build run-camera
zig build run-tilemap
zig build run-primitives
zig build run-breakout
zig build run-breakout-sdl
zig build smoke-breakout-sdl
zig build test-breakout
zig build run-topdown-sdl
zig build run-topdown-multiplayer
zig build smoke-topdown-sdl
zig build test-topdown
zig build test-topdown-multiplayer
zig build test-topdown-scene
zig build run-platformer-sdl
zig build smoke-platformer-sdl
zig build test-platformer
zig build test-replays
zig build test-fuzz
script/check_performance_budgets.sh
zig build test-scenes
zig build stress-audio-sdl
zig build new -- ../my-game
zig build upmapc -- level.upmap level.upmapb
```

`run-bounce` renders `zig-out/bounce.ppm`.
`run-bounce-sdl` opens an SDL3 window.
`dev-bounce` opens a PNG/text live-reload demo.
`run-audio` opens a WAV/OGG audio demo.
`run-explicit-loop` opens the caller-owned-state SDL loop demo.
`run-atlas` opens a JSON atlas/tile scene demo.
`run-camera` opens the resizable multi-viewport camera demo.
`run-tilemap` opens the sparse tile-map and camera-culling demo.
`run-primitives` opens the GPU primitive and text-quads demo.
`run-breakout` writes the deterministic Breakout frame to `zig-out/breakout.ppm`.
`run-breakout-sdl` opens Breakout with keyboard paddle input and collision audio.
`smoke-breakout-sdl` runs two SDL frames with a dummy audio device.
`test-breakout` runs fixed-step Breakout simulation tests.
`run-topdown-sdl` opens the action-mapped Tiled top-down demo.
`run-topdown-multiplayer` runs the seeded two-client authoritative top-down smoke.
`smoke-topdown-sdl` runs two SDL frames with dummy audio.
`test-topdown` and `test-topdown-scene` verify deterministic simulation and rendering.
`test-topdown-multiplayer` verifies two faulted clients converge on the authoritative state.
`run-platformer-sdl` runs the TileCollider, Box2D, animation, and shader platformer slice.
`smoke-platformer-sdl` and `test-platformer` verify its bounded runtime and movement fixture.
`test-replays` verifies stored fixed-step input state hashes for Breakout, top-down, and platformer on CI.
`test-fuzz` runs bounded asset/map and network-parser corpus mutations with leak checks.
`script/check_performance_budgets.sh` records release-mode startup, frame, allocation, and headless-renderer metrics, then applies the versioned baseline for the host target.

`zig build peas -- package macos [output-directory]` writes a universal macOS bounce app, archive, checksum, and runtime/assets manifest; `script/test_macos_package.sh` launches its bounded smoke outside the repository.
`zig build peas -- package linux [output-directory]` writes an x86_64 Linux bounce archive, checksum, and runtime/assets manifest; `script/test_linux_package.sh` verifies bundled SDL linkage, asset layout, and bounded smoke outside the repository.
`test-scenes` compares a deterministic headless scene against a committed PNG golden; `zig build test-scenes -- --update-golden` refreshes it intentionally.
`stress-audio-sdl` runs a local SDL audio stress smoke.
`zig build peas -- new <directory>` creates the bouncing-square starter project; it writes a standalone build, source, asset, and manifest layout without replacing an existing destination.
`zig build peas -- check [project-directory] [--target <linux|macos>]` statically validates the manifest, project build script, native source, assets, engine/Zig compatibility, and selected runtime target without starting the game; failures include a recovery command.
`zig build peas -- test <unit|replay|visual|integration> [project-directory]` runs the selected deterministic test target and identifies its build artifact directory on failure.
`zig build peas -- package <linux|macos> [output-directory]` creates the selected portable archive through the project CLI.
`zig build peas -- docs [overview|quickstart|testing|api]` emits offline Markdown documentation and prints its local path; `zig build test-docs` validates runnable-example links.
`zig build peas -- run [project-directory] -- [game-args]` discovers the project from the selected path, validates `assets/`, and starts the Debug runtime with forwarded game arguments.
When `peas run` or `peas test` encounters a known Zig engine/config diagnostic, it preserves the native text and appends a concise `peas recovery` hint.

Mixer playback supports `pan`, `setPlaybackPan`, and sample-frame `fadePlayback`; OGG music preallocates a bounded decode buffer, and SDL output reopens after device removal or format changes without resetting mixer playback state.

Bundled read-only assets resolve from `assets/` beside the executable or one directory above it; `UP_ASSET_ROOT` or absolute `Config.asset_root` override this for development and embedding. Writable data uses `Context.appDataPath`.

## Developer Runtime

`Config.developer_tools` defaults to enabled in Debug builds. F3 toggles the FPS/frame-time overlay. F12 writes a PNG read back from the composed GPU render target. `Context.captureFrame()` requests the same capture after the current frame. The app-data path is printed at startup, available through `Context.appDataPath`, and contains `unpolished-peas.log` when developer tools are enabled.

Game initialization, event, update, draw, GPU-recovery, and asset-reload errors include their phase and log path in the terminal, are written to the app-data log, then stay in an in-window error state until Escape or close. A GPU reset rebuilds presenter resources and invalidates prior handles; a GPU loss reports a terminal recovery failure. Zig panics remain process failures and require the normal debugger/test workflow.

SDL sprite textures upload on first use; changed image or atlas buffers stage a replacement upload before the prior GPU resource is released, and unused sprite resources expire after 120 rendered frames. Atlas draws preserve source regions, origin, scale, rotation, flips, tint, and nearest or linear sampling through the GPU path.

GPU command primitives use one logical-pixel strokes, 32-segment circles, and source-over or additive blending. `Context.pushClip`/`popClip` and `pushBlend`/`popBlend` nest and restore command state.

Tiled object layers retain rectangle, ellipse, point, polygon, and polyline collision shapes plus typed string, integer, float, and boolean properties. Tile rendering applies inherited visibility, offsets, parallax, opacity, and flip flags.

`TileCollider.addLayer` derives deterministic solid geometry from an explicit tile, IntGrid, or object layer. Object/layer `one_way=true` surfaces are pass-through from below; polygon and polyline edges provide walkable slopes. `CharacterController.move` is a swept, bounded-step controller with grounded, wall, and ceiling state.

`Context.loadShader` loads a validated `.upshader` resource (`effect=invert` plus `uniform amount:f32`, or `effect=passthrough`). `Context.setShaderEffect` replaces the post-process chain; `Context.appendPixelEffect` appends a pass. Passes execute in declared order through owned ping-pong targets, screenshots capture the final target, and invalid shader reloads retain the last good program. `Canvas.applyPixelEffect` is the defined headless fallback.

## Camera And Presentation

`Camera2D` provides position, zoom limits, rotation, viewport rectangles, world bounds, nearest or bilinear image sampling, pixel snapping, dead-zone follow, spring motion, deterministic shake, coordinate conversion, visibility checks, and parallax copies. `CameraRig` owns an arbitrary number of generation-checked cameras; `CameraDirector` plays deterministic cuts and blended shots.

Use `ctx.camera(&camera)` for world rendering. It transforms and clips rectangles, circles, lines, images, atlas frames, and text to the camera viewport. Use the existing `ctx` drawing calls for HUD rendering.

SDL windows support `Config.resizable` and `.stretch`, `.fit`, or `.integer_fit` presentation. `Input.pointer` exposes window, physical framebuffer, and optional logical-canvas coordinates; letterbox bars map to `null` canvas coordinates.

## Current API

- `Vec2`, `Rect`
- `Color`
- `Input`, `Key`
- `Pointer`, `PointerButton`
- `Action`, `ActionBinding`, `ActionMap`
- `FontGlyphRange`, `FontTextDiagnostics`
- `StepClock`
- `Canvas`, `Sprite`
- `Canvas.drawImage`
- `Canvas.drawAtlasFrame`
- `Canvas.drawText`
- `Camera2D`, `CameraCanvas`, `CameraRig`, `CameraDirector`
- `TileMap`, `TileMapLayer`, `TileMapLayerKind`, `TileMapObject`, `TileMapObjectShape`, `TileMapProperty`, `TileSet`, `TileMapHandle`
- `TileMap.loadNative`, `TileMap.loadTiled`, `TileMap.loadLdtkProject`
- `TileCollider`, `CharacterController`
- `netCodec` (`v1`, little-endian, 1024-byte bounded messages)
- `NetTransport`, `LoopbackTransport`
- `UdpTransport`, `UdpTransportConfig`
- `netHandshake`, `HandshakeClient`, `HandshakeServer`
- `netPeer`, `PeerServer`
- `netChannel`, `NetChannel`
- `netSnapshot`, `SnapshotPublisher`, `SnapshotClient`
- `netEcsReplication`, `EcsReplicationAdapter`
- `netSession`, `NetHost`, `NetClient`
- `netSync`, `SnapshotInterpolator`, `InputCommandClient`
- `netFault`, `FaultNetwork`, `FaultEndpoint`
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

1. Publish future tagged package releases and update the starter dependency URL and hash.
2. Complete external tile-source blitting and compressed/external Tiled fixture coverage for the tile-map compatibility layer.
3. Add an opt-in ECS with generation-checked entities, sparse component stores, deterministic queries, and no hidden scheduler; keep direct struct-based games first-class.
4. Add gamepad support plus named action mapping, rebinding, and deterministic input tests.
5. Add a shader API with one strict pixel-effect example and headless fallback coverage.
6. Add project packaging, desktop release artifacts, and web export after desktop assets, audio, camera, and input are stable.
