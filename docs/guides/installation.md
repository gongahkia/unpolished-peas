# Install Peas from a release

Peas requires Zig `0.15.2`.

> **UNRELEASED / prepared for v0.1.0:** no immutable Peas release archive or
> Zig package hash is public yet. The declaration below documents the release
> contract; it is not currently copy-and-run installation data. Until a tag is
> published, use a source checkout to evaluate Seed Sprint as described in
> [Start here](quickstart.md).

## Add the dependency

After `v0.1.0` is published, the canonical Seed Sprint checkout will contain
the reviewed declaration. For a new project, fetch that immutable release
asset once to get the exact Zig package hash, then copy both values together:

```sh
zig fetch <v0.1.0-source-archive-url>
```

The command prints a value beginning with `unpolished_peas-`. Use that exact
value in `build.zig.zon`; never substitute a hash from another version.

```zig
.dependencies = .{
    .unpolished_peas = .{
        .url = "<v0.1.0-source-archive-url>",
        .hash = "<exact output from zig fetch>",
    },
},
```

`script/prepare_starter_release.sh v0.1.0` writes those real coordinates into
the starter before the release tag is made. The generated source archive omits
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
