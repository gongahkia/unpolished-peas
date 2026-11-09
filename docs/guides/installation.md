# Installation, dependencies and packaging

For the complete create → play → test → web walkthrough, use the
[quickstart](quickstart.md). This page owns prerequisites, dependency modes
and output layout. [Releases and support](releases.md#current-release) records
which version and package assets are actually published; these instructions
follow the current source checkout.

## Requirements

- Zig `0.15.2` on your PATH (`zig version` prints the installed version).
  Choose that version from the [official downloads](https://ziglang.org/download/);
  the latest compiler is not automatically compatible with this checkout.
- A current Peas checkout for generation. Run engine commands from its root,
  then game commands from the generated directory.
- Network access for uncached pinned dependencies. The native build fetches
  and compiles SDL3; no separately installed SDL or `pkg-config` is required.
- A working desktop display/driver for native play. Build success alone does
  not establish interactive support; see [platform evidence](platforms.md).
- An HTTP server for browser play. The quickstart uses Python 3; the optional
  `dev-web` watcher also requires `python3`. Static output has no Python
  dependency. Node.js is used by engine verification, not by a generated game.

## From a source checkout

From the Peas root, choosing a new destination directory:

```sh
zig build peas -- new ../my-game
```

Continue in `../my-game` with the [quickstart](quickstart.md#create-and-play).
`zig build new -- ../my-game` is an equivalent generator entry point. Both
write a `.dependencies.unpolished_peas.path` relative to the generated game
and pointing to the checkout that ran the generator. Paths with spaces work
when quoted. Keep the game and engine at the same relative locations, or
update that dependency when moving them. This is a live development dependency:
engine edits affect the next game build. Record the engine commit alongside
your game when you need to reproduce a particular checkout.

The generator supplies the dependency declaration, native/browser build
steps, assets and deterministic tests. No manifest repair or internal engine
imports are needed. Portable game code imports `unpolished-peas`; only the
native wrapper imports `unpolished-peas-sdl3`. Keep the generated build graph
until your game needs a specific change.

## Pin a prepared release

This mode requires a prepared release checkout whose starter template contains
its archive URL and Zig package hash. It is unavailable in an unprepared
checkout. See [current package availability](releases.md#current-release)
before using it. From that prepared checkout:

```sh
zig build peas -- new ../my-game --release
```

The generator runs `zig fetch` against the supplied URL and requires the
returned package hash to match before creating the game. The manifest retains
that verified pair and has no local engine path. Missing coordinates, a failed
fetch or a mismatched hash fail generation without leaving a project directory.
Omitting `--release` selects the local-checkout dependency even in a prepared
release checkout.

### Release dependency format

Use the URL and hash together from the prepared template for that version;
never guess either value or mix versions. Maintainers prepare the archive and
its coordinates using the [release contract](releases.md#release-contract).
Game authors do not need to run release-preparation scripts. The existing
archive consumer checks exercise this mode with real locally served archives
and computed hashes, without publishing a release.

## Browser and package

These commands run **inside the generated game**, in either dependency mode:

| Command | Result |
| --- | --- |
| `zig build` | Native executable and runtime assets under `zig-out/` |
| `zig build run` | Build and open the game; close its window to exit |
| `zig build test` | Run the starter's headless deterministic tests |
| `zig build web` | Static browser bundle under `zig-out/web/` |
| `zig build dev-web` | Local watch/build/serve/full-page-refresh loop; Python 3 required |
| `zig build package` | The same native executable-plus-assets layout as `zig build` |

The browser bundle includes:

```text
zig-out/web/
├── index.html
├── unpolished-peas.wasm
├── bootstrap.mjs
├── host.mjs
├── debug-font-v1.json
└── assets/
```

Additional runtime `.mjs` modules are part of this directory too. Copy the
**whole directory**, preserving relative paths and matching Wasm/host versions.
Serve it over HTTP as in the [quickstart](quickstart.md#test-and-run-in-a-browser);
opening HTML directly does not support the module/Wasm loading workflow.
See [browser development](browser-development.md) for reload, saves and audio
activation, and [rendering choices](rendering.md#choose-a-rendering-path)
before forcing a backend.

The desktop layout is `zig-out/bin/seed-sprint` (`seed-sprint.exe` on Windows)
and `zig-out/assets/`. Distribute both with their relative layout intact and
include the applicable asset/third-party notices. This is a local package,
not a signed app bundle, installer or validated build for another OS.

### Release artifact scope

Maintainer scripts can also produce versioned Linux tarballs, macOS universal
ZIP layouts and web directories. They do not create signed `.app` bundles,
DMGs, AppImages, deb/rpm packages or installers. Availability and unresolved
release decisions live in [releases and support](releases.md).

## Platform status

[Platform evidence](platforms.md) separates build/package and observed runtime
coverage. The [capability matrix](capabilities.md) owns renderer support status.
Neither source generation nor local packaging promotes a preview target.

## Linux and WSLg troubleshooting

Peas leaves SDL's normal video-driver selection untouched. Startup writes one
compact native-renderer record containing the selected SDL video driver, the
requested and selected renderer, fallback status, and any failed backend
attempt with its SDL error text. That record is useful before changing an
environment or filing a renderer issue.

For diagnosis only, a desktop project may ask SDL to try one installed Linux
driver for a single invocation:

```sh
SDL_VIDEODRIVER=wayland zig build run
SDL_VIDEODRIVER=x11 zig build run
```

Do not bake either override into a game or package. WSLg can be useful for
development, but its X11/Wayland bridge, D3D12-backed Vulkan path, PulseAudio
bridge, and input stack are not evidence of bare-metal Linux behavior. A
missing display fails before renderer fallback with a bounded diagnostic; it
does not mean the game's renderer is broken.
