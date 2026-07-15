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

- Zig 0.15.1 or 0.15.2
- no system SDL3 installation in the default pinned-source mode

```sh
zig build test-sdl
zig build test-renderer-conformance
```

`zig build test-sdl` uses the pinned SDL3 source in `build.zig.zon`. The pinned Box2D source is reserved for the optional physics module and is validated with `zig build test-box2d`.
`test-renderer-conformance` runs the shared canvas smoke/golden fixture and an opt-in GPU capture golden. CI requires the GPU capture on macOS and Linux; Windows emits its platform, drivers, and shader-format capability report when no compatible GPU backend is available. Windows runtime uses dynamically compiled DXBC shaders for the D3D backend.

The `unpolished-peas` core module has no SDL3 dependency. Import `unpolished-peas-sdl3` separately only for the desktop runtime.

Published modules are `unpolished-peas` (core), `unpolished-peas-sdl3` (desktop runtime), `unpolished-peas-effects` (GPU resources), `unpolished-peas-tools` (host CLI helpers), `unpolished-peas-test` (deterministic test fixtures), and `unpolished-peas-services` (SDL-free online-service contracts). Tools and services import no desktop runtime; `zig build test-modules` checks the independent core, tools, test fixtures, and services graph.

`services/` is an independent local Zig workspace. Copy `services/config/local.zon.example`, set an absolute `secrets_path`, then run `script/run_local_services.sh <config.zon>`; `--once` binds and exits for local/CI validation. Engine provider contracts contain no database or vendor types; the opt-in local PostgreSQL adapter is isolated behind that boundary.
`services/config/deploy.zon.example` and `services/deploy/unpolished-peas-services.service` keep database credentials external; `/healthz` reports liveness and `/readyz` probes PostgreSQL plus the configured relay without enabling engine telemetry.
Run `script/services_bootstrap_db.sh <postgresql-url>` to apply the checksummed, transactional service migrations; rerunning it verifies and preserves the recorded schema version.
`GuestToken` uses 256-bit random values; `GuestCredentialStore` atomically keeps only active identity/session credentials under the caller-provided app-data directory and removes expired records.
`ServiceProvider` is the engine-facing, value-only guest-session boundary: use `FakeServiceProvider` in engine tests or `LocalPostgresServiceProvider` for local PostgreSQL. Its only operational dependency is the local `psql` CLI; provider errors are limited to unavailable, invalid-request, and invalid-response. A provider borrows its adapter; deinit the adapter after its provider is no longer used.
`LobbyService` is the SDL-free guest-backed lobby boundary: create, join, leave, disconnect, expiration, bounded membership, and `inspectorState()` use only validated guest sessions.
`MatchmakingService` queues active lobby members under bounded timeout/capacity rules and returns an idempotent match bootstrap usable by the P2P runtime.
`RelayService` derives bounded relay routes from authorized match requests, seals each route ticket to its guest session with XChaCha20-Poly1305, expires leases, and caps concurrent relay connections and transmitted bytes.
`NetContract` explicitly selects authoritative or peer-to-peer mode, host role, and channel reliability; its identity, session, and connection values own no transport and validate bounded IDs, expiry, protocol, and connection limits.
`P2pMigration` elects the lowest active peer after a host failure and returns a bounded versioned game-state snapshot for deterministic reconnect over the selected direct or relay route.

[fixtures/modules](fixtures/modules) is a downstream SDL-free import fixture for core, tools, and services.

`unpolished-peas-physics` is a separate optional Box2D module with explicit `World.init`, body/shape/joint handles, contacts, camera-aware debug commands, `step`, and `deinit`; the core module and generated starter do not link Box2D.
`World.appendDebug` emits the same core render commands for headless and GPU presentation.
The SDL runtime wires only `InspectorAssetPanel`, `InspectorInputPanel`, and `InspectorMetricsPanel`; disabled developer tools retain no panels and execute no inspector rendering. Collision, physics, and network panels remain explicitly application-owned. `unpolished-peas-physics` provides `World.inspectorState()` for the optional `InspectorPhysicsPanel`.

`Context.text` uses the built-in 5×7 debug font. `AssetStore.loadFont(path, options)` loads TrueType/OpenType fonts into a GPU atlas and detects AngelCode `.fnt` descriptors; configure `FontLoadOptions.ranges` with one or more Unicode ranges. `Context.font` uses strict UTF-8 replacement and the configured fallback glyph, while `Font.textDiagnostics` exposes invalid UTF-8 and missing/fallback glyph counts. `layoutText` shares the same deterministic UTF-8 decoder.

`Image.decode` and `AssetStore.loadImage` accept PNG, JPEG, and TGA with a 32 MiB input cap, 4096×4096 dimension caps, and a 16 MiB pixel cap; pass `ImageDecodeOptions` to tighten direct decoder limits.

To use a system SDL3 instead:

```sh
brew install sdl3 pkg-config
zig build -Dsystem-sdl=true run-bounce-sdl
```

On Debian or Ubuntu, replace the `brew install` command with `sudo apt install libsdl3-dev pkg-config`.

## Tiny Start

```zig
const core = @import("unpolished-peas").api.core;
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{ .width = 80, .height = 60, .scale = 6 };

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.rect(18, 18, 28, 28, core.Color.rgb(255, 198, 74));
        ctx.text("HELLO", 8, 8, core.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
```

## Explicit Loop

sdl.playGame(Game) is the callback-game facade and reads window, presentation, developer, asset-root, and lifecycle configuration from Game.config. sdl.run(config, state, callbacks) is the caller-owned escape hatch; [examples/explicit_loop.zig](examples/explicit_loop.zig) compiles without a Game type.

Set Game.config.pause_policy to .unfocused or .minimized to suppress update callbacks while that desktop state applies. Focus, minimize, restore, resize, and close stay ordered Event callbacks; draw continues with ctx.dt set to zero, leaving game state under user control.

Each unpaused frame processes input/events, runs zero or more update callbacks at fixed `1 / Config.fixed_hz` `ctx.dt`, then runs one draw callback with clamped variable `ctx.dt`; `ctx.alpha` is the remaining fixed-step fraction for draw interpolation. Frame deltas are capped at `StepClock.max_steps_per_frame * step_seconds`; paused draws receive zero `dt` and `alpha` without advancing the clock.

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
zig build test-effects
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
zig build run-topdown-dedicated
zig build run-topdown-listen
zig build run-topdown-listen-sdl
zig build smoke-topdown-sdl
zig build test-topdown
zig build test-topdown-multiplayer
zig build test-topdown-hosts
zig build test-topdown-scene
zig build run-platformer-sdl
zig build smoke-platformer-sdl
zig build test-platformer
zig build test-replays
zig build test-fuzz
zig build benchmark
zig build benchmark-proofs
script/check_performance_budgets.sh
zig build test-scenes
zig build stress-audio-sdl
zig build new -- ../my-game
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
`run-topdown-sdl` opens the action-mapped native-map top-down demo.
`run-topdown-multiplayer` runs the seeded two-client authoritative top-down smoke.
`run-topdown-dedicated` runs the core-only UDP dedicated-host sample; `run-topdown-listen` runs the matching loopback listen-host sample; `run-topdown-listen-sdl` opens the in-game listen-host path.
`smoke-topdown-sdl` runs two SDL frames with dummy audio.
`test-topdown` and `test-topdown-scene` verify deterministic simulation and rendering.
`test-topdown-multiplayer` verifies two faulted clients converge on the authoritative state.
`test-topdown-hosts` verifies both host samples use the shared top-down rules.
`run-platformer-sdl` runs the TileCollider, Box2D, animation, and shader platformer slice.
`smoke-platformer-sdl` and `test-platformer` verify its bounded runtime and movement fixture.
`script/test_proof_game_matrix.sh <topdown|platformer>` runs bounded CLI, inspector, reload, profiler, headless, network, and desktop-smoke scenarios; CI runs its Windows equivalent on every supported desktop and retains `zig-out/diagnostics/proof-matrix/` on failure.
`fixtures/bounce-project`, `fixtures/topdown-project`, and `fixtures/platformer-project` are independent consumer packages that import `unpolished-peas` through their own manifests; `script/test_independent_proof_games.sh` builds and tests all three. The top-down and platformer projects also provide native reference content: `peas compile` emits map and asset-catalog caches, while their unit/replay/visual/integration targets run through `peas test`.
`fixtures/external-game` is a standalone callback game that draws a sprite, plays synthesized audio, and consumes normalized input through the public desktop module.
`fixtures/external-tilemap-game` is a standalone desktop game that loads native asset/map sources, drives movement through configured actions, follows with a camera, and exercises catalog-backed asset reloads.
`fixtures/external-animation-game` is a standalone desktop game that animates a generated atlas, plays synthesized audio, uses swept collision, and exposes capture/CPU-trace diagnostic hooks.
`release-zig-compatibility` runs core tests, replay hashes, and independent proof-game packages on Zig 0.15.1 and 0.15.2.
`test-extensions` resolves the versioned extension fixture against the frozen core range and compares its deterministic lock.
`test-extension-manifest` validates strict extension identity, semver/core range, module, test, and optional build-hook metadata.
`script/test_effects_package.sh` builds the isolated effects package and an external consumer fixture.
`script/test_extension_matrix.sh` resolves every declared optional package/core pair, then runs that package's focused build target.
`test-replays` verifies stored fixed-step input state hashes for Breakout, top-down, and platformer on CI.
`test-fuzz` runs bounded asset/map and network-parser corpus mutations plus fixed-seed authoritative/P2P fault matrices; proof packets converge or enter defined failures under loss, duplication, reordering, latency, bandwidth, and malformed input.
`script/check_performance_budgets.sh` records release-mode engine and bounce/top-down/platformer startup, frame, and allocation metrics, then applies versioned host-target baselines.
Tag pushes run `zig build release-gate`, which explicitly validates the frozen core API, all proof-game consumers, desktop packages, deterministic diagnostics, visual/replay/fuzz checks, and performance budgets; every gate writes a local log under `zig-out/diagnostics/release-gate/`.

`zig build peas -- package <linux|macos|windows> [output-directory] [--game <bounce|topdown|platformer>]` writes a portable archive with uniform `bin/`, `assets/`, native `content/` with compiled caches, `docs/`, `launcher.json`, `run.sh`/`run.cmd`, package manifest, and SHA-256 checksum; bounce, top-down, and platformer package smokes run outside the repository and emit reports.
`test-scenes` compares deterministic headless, bounce, top-down, and platformer renders against committed PNG goldens; `zig build test-scenes -- --update-golden` refreshes all captures intentionally.
`stress-audio-sdl` runs a local SDL audio stress smoke.
`zig build peas -- new <directory>` creates the bouncing-square starter project; it writes a standalone build, source, assets, and build-manifest layout without replacing an existing destination.
`zig build peas -- check [project-directory] [--target <linux|macos|windows>]` statically validates the manifest Zig minimum, project build script, `assets/`, `maps/`, and selected runtime target without starting the game; Windows checks require Windows 10/11 x64 with `D3DCompiler_47.dll`; failures include a recovery command.
`.upassets` is the strict version-1 ZON asset catalog. It requires the `unpolished-peas-assets` format and explicitly lists image, audio, font, atlas, and shader assets by unique ID and safe relative path; `up.assetCatalog.parse`, `load`, and `graph` validate, bind `AssetStore` handles, and expose declared dependencies.
`up.mapSource` parses strict version-1 ZON native map source with tilesets, sparse signed cells, object geometry, collision properties, and parented layers; invalid references report source locations.
`zig build contentc -- <project-directory> [output-directory]` emits versioned `.upc` binary caches for `.upassets` files under `assets/` and `.upmap` files under `maps/`; cache headers validate magic, version, kind, size, and source fingerprint before reuse. `zig build peas -- compile [project-directory] [output-directory]` provides the same project workflow.
`zig build peas -- migrate <catalog|map> <input> <output>` explicitly upgrades supported source versions and writes only the requested output path; unsupported versions include a recovery command.
`zig build peas -- test <unit|replay|visual|integration> [project-directory]` runs the selected deterministic test target and identifies its build artifact directory on failure.
`zig build peas -- replay <fixture.upr> [expected-input-hash]` reproduces normalized fixed-step input and reports a deterministic final-state hash or divergence.
`zig build peas -- package <linux|macos|windows> [output-directory] [--game <bounce|topdown|platformer>]` creates the selected portable archive through the project CLI.
`zig build peas -- docs [overview|quickstart|testing|api]` emits offline Markdown documentation and prints its local path; `zig build test-docs` validates runnable-example links.
`zig build peas -- run [project-directory] -- [game-args]` discovers the project from the selected path, validates `assets/`, and starts the Debug runtime with forwarded game arguments.
`zig build peas -- host <dedicated|listen> [--bind <ip>] [--port <u16>] [--max-peers <1..64>] [--ticks <1..100000>]` validates a bounded host launch configuration and identifies the matching sample target.
When `peas run` or `peas test` encounters a known Zig engine/config diagnostic, it preserves the native text and appends a concise `peas recovery` hint.

Mixer playback supports `pan`, `setPlaybackPan`, and sample-frame `fadePlayback`; OGG music preallocates a bounded decode buffer, and SDL output reopens after device removal or format changes without resetting mixer playback state.

Bundled read-only assets resolve from `assets/` beside the executable or one directory above it; `UP_ASSET_ROOT` or absolute `Config.asset_root` override this for development and embedding. Writable data uses `Context.appDataPath`.

## Developer Runtime

`Config.developer_tools` defaults to enabled in Debug builds. F3 toggles the FPS/frame-time overlay. F12 writes a PNG read back from the composed GPU render target. `Context.captureFrame()` requests the same capture after the current frame. The app-data path is printed at startup, available through `Context.appDataPath`, and contains `unpolished-peas.log` when developer tools are enabled.

Game initialization, event, update, draw, GPU-recovery, and asset-reload errors include their phase and log path in the terminal, are written to the app-data log, then stay in an in-window error state until Escape or close. A GPU reset rebuilds presenter resources and invalidates prior handles; a GPU loss reports a terminal recovery failure. Zig panics remain process failures and require the normal debugger/test workflow.

`Config.cpu_profiler` defaults to Debug builds. The runtime measures callback, update, draw, and asset-reload scopes; use `ctx.profile(.asset)` around game-owned work, inspect `ctx.profileMetrics()`, and call `ctx.exportCpuTrace()` to write Chrome Trace JSON to the app-data directory.

`ctx.runtimeMetrics()` reports the last completed frame's CPU encoder time, pass and batch counts, texture and audio-buffer usage, plus resource/allocation churn. Hardware GPU timing is `null` because this SDL runtime does not issue timestamp queries; the developer inspector renders that state explicitly.

Runtime failures write bounded local diagnostics: versioned `metadata.json`, `screenshot.png`, `commands.json`, `trace.json`, and `failure.log`. Golden/replay test failures add deterministic diagnostics under `zig-out/diagnostics`; set `UP_DIAGNOSTICS_ROOT` to redirect runtime captures for CI. Diagnostics are local artifacts and contain no transmitted telemetry.

SDL sprite textures upload on first use; changed image or atlas buffers stage a replacement upload before the prior GPU resource is released, and unused sprite resources expire after 120 rendered frames. Atlas draws preserve source regions, origin, scale, rotation, flips, tint, and nearest or linear sampling through the GPU path.

GPU command primitives use one logical-pixel strokes, 32-segment circles, and source-over or additive blending. `Context.pushClip`/`popClip` and `pushBlend`/`popBlend` nest and restore command state.

`TileCollider.addShape` and `addLayer` are the default collision path. `addLayer` derives deterministic solid geometry from an explicit tile, IntGrid, or object layer; failures leave the existing collider unchanged. Object/layer `one_way=true` surfaces are pass-through from below; polygon and polyline edges provide walkable slopes. `CharacterController.move` is a swept, bounded-step controller with grounded, wall, and ceiling state.

`unpolished-peas-effects` owns shader programs, pixel effects, and post-process chains. `Context.loadShader` loads `.upshader` source; `Context.setShaderEffect` validates and replaces the post-process chain, while `Context.appendPixelEffect` appends a pass. Passes execute in declared order through owned ping-pong targets, screenshots capture the final target, and `effects.applyPixelEffect` is the headless fallback.

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
- `MapSource`, `mapSource`
- `TileCollider`, `CharacterController`
- `netCodec` (`v1`, little-endian, 1024-byte bounded messages)
- `NetTransport`, `LoopbackTransport`
- `UdpTransport`, `UdpTransportConfig`
- `netHandshake`, `HandshakeClient`, `HandshakeServer`
- `netPeer`, `PeerServer`
- `netChannel`, `NetChannel`
- `netP2p`, `P2pPeer`, `P2pRoute`
- `netNat`, `NatGatherer`, `NatTraversalClient`
- `netSnapshot`, `SnapshotPublisher`, `SnapshotClient`
- `netEcsReplication`, `ReplicationSchema`, `ReplicationStateAdapter`, `SceneReplicationAdapter`, `EcsReplicationAdapter`
- `netSession`, `NetHost`, `NetHostRole`, `NetClient`
- `netSync`, `SnapshotInterpolator`, `InputCommandClient`, `PredictionClient`, `AuthoritativeServer`
- `netFault`, `FaultNetwork`, `FaultEndpoint`
- `Presentation`, `PresentationMode`
- `AssetFile`
- `AssetStore`
- `Image`
- `Atlas`
- `AtlasFrameHandle`
- `AnimationPlayer`
- `AnimationStateMachine`, `AnimationState`, `AnimationTransition`, `animationState`
- `ParticleEmitter`, `ParticleConfig`, `ParticleMetrics`, `particles`
- `FrameProfiler`, `ProfileScope`, `ProfileMetrics`, `profiler`
- `RuntimeMetrics`, `InspectorMetricsPanel`, `runtimeMetrics`
- `LightingPipeline`, `LightingConfig`, `Light`, `LightOccluder`, `LightingRenderPath`, `lighting`
- `UiFrame`, `UiState`, `UiLayout`, `UiStyle`, `UiSurface`, `ui`

`LightingPipeline.append` emits GPU primitive commands; `LightingPipeline.render` is the explicit headless fallback selected by `LightingPipeline.preferredPath`.

`ui.Frame` is immediate-only: callers retain `UiState`, emit widgets every frame, and finish with `Frame.end` to resolve navigation.
- `Sound`
- `Music`
- `AudioMixer`
- `BusHandle`
- `PlaybackHandle`
- `unpolished-peas-sdl3.playGame`, `unpolished-peas-sdl3.Context`
- `unpolished-peas-sdl3.run` for lower-level control
- `unpolished-peas-sdl3.appDataPath`

## Next Build Targets

1. Publish future tagged package releases and update the starter dependency URL and hash.
2. Add an opt-in ECS with generation-checked entities, sparse component stores, deterministic queries, and no hidden scheduler; keep direct struct-based games first-class.
3. Add gamepad support plus named action mapping, rebinding, and deterministic input tests.
4. Add a shader API with one strict pixel-effect example and headless fallback coverage.
5. Add project packaging, desktop release artifacts, and web export after desktop assets, audio, camera, and input are stable.
