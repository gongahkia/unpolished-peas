# Install Peas from a release

Peas requires Zig `0.15.2`.

The current version is **1.0.0**. Its [GitHub release](https://github.com/gongahkia/unpolished-peas/releases/tag/1.0.0)
is published, but has no prepared source-package archive, Zig package hash, or
desktop downloads attached. The declaration below describes the packaging
contract; it is not copy-and-run installation data. Use the source-checkout
workflow in [Start here](quickstart.md) to evaluate Seed Sprint today.

## Add the dependency

Once a release includes the prepared package assets, its Seed Sprint checkout
will contain the reviewed declaration. For a new project, fetch that immutable
asset once to get the exact Zig package hash, then copy both values together:

```sh
zig fetch <published-source-archive-url>
```

The command prints a value beginning with `unpolished_peas-`. Use that exact
value in `build.zig.zon`; never substitute a hash from another version.

```zig
.dependencies = .{
    .unpolished_peas = .{
        .url = "<published-source-archive-url>",
        .hash = "<exact output from zig fetch>",
    },
},
```

`script/prepare_starter_release.sh <new-tag>` writes those real coordinates into
the starter before a new release tag is made. Do not rewrite the existing
`1.0.0` tag. The generated source archive omits
that manifest to keep its bytes—and therefore its Zig hash—stable.

## Import and run

Normal game source imports only supported modules:

```zig
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
```

Start from [Seed Sprint](../../templates/starter/README.md). Its `build.zig`
imports the desktop and browser modules through the supported package boundary;
game source does not import Peas internals.

## Browser and package

Inside a released standalone Seed Sprint project, these are the normal
commands:

```sh
zig build
zig build run
zig build test
zig build web
zig build package
```

`zig build web` produces a self-contained browser directory:

```text
zig-out/web/
├── index.html
├── unpolished-peas.wasm
├── bootstrap.mjs
├── host.mjs
└── assets/
```

Serve it over HTTP—for example,
`python3 -m http.server --directory zig-out/web 8000`—then open the reported
local URL. Opening the HTML file directly is not supported by browser module
and Wasm loading rules.

For local iteration, `zig build dev-web` watches the project, invokes this
same `web` build, serves its last successful output on `127.0.0.1`, and fully
refreshes the page after a successful rebuild. It is development-only; see
the [browser development guide](browser-development.md) for failed-build,
audio, persistence, and WSL behavior.

`zig build package` creates the starter's local `zig-out/bin/seed-sprint` and
`zig-out/assets/` layout. It is a portable executable-plus-assets directory,
not a signed `.app`, DMG, AppImage, deb/rpm package, or installer.

## Release artifact scope

The Peas release scripts additionally prepare versioned Linux tarballs, macOS
universal ZIP layouts, and web directories. They do not create signed `.app`
bundles, DMGs, AppImages, deb/rpm packages, or installers.

## Platform status

See the canonical [platform status](platforms.md) page for actual
build/package and runtime evidence, and the [capability matrix](capabilities.md)
for renderer-specific API/CI contract coverage.

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

## Current legal blocker

This repository currently has no code license. The technical release workflow
can be prepared, but publishing or adopting it remains legally blocked until
the project owner selects and adds a license.
