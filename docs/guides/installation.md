# Install Peas from a release

Peas requires Zig `0.15.2`. Its intended first immutable release is `v0.1.0`.
Until that tag and its source archive are published, use a source checkout only
for framework development; it is not an external dependency coordinate.

## Add the dependency

After `v0.1.0` is published, the canonical Seed Sprint checkout contains the
reviewed declaration. For a new project, fetch the release asset once to get
the exact Zig package hash, then copy both values together:

```sh
zig fetch https://github.com/gongahkia/unpolished-peas/releases/download/v0.1.0/unpolished-peas-v0.1.0-source.tar.gz
```

The command prints a value beginning with `unpolished_peas-`. Use that exact
value in `build.zig.zon`; never substitute a hash from another version.

```zig
.dependencies = .{
    .unpolished_peas = .{
        .url = "https://github.com/gongahkia/unpolished-peas/releases/download/v0.1.0/unpolished-peas-v0.1.0-source.tar.gz",
        .hash = "<exact output from zig fetch>",
    },
},
```

`script/prepare_starter_release.sh v0.1.0` writes those real coordinates into
the starter before the release tag is made. The generated source archive omits
that manifest to keep its bytes—and therefore its Zig hash—stable.

## Import and run

Start from [Seed Sprint](../../templates/starter/README.md), then run:

```sh
zig build
zig build run
zig build test
zig build web
zig build package
```

Normal game source imports only supported modules:

```zig
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
```

The starter's browser target uses the supported
`unpolished-peas-browser-runtime` build module. It emits this static directory:

```text
zig-out/web/
├── index.html
├── unpolished-peas.wasm
├── bootstrap.mjs
└── assets/
```

Serve `zig-out/web` over HTTP—for example,
`python3 -m http.server --directory zig-out/web 8000`—then open the reported
local URL. Opening the HTML file directly is not supported by browser module
and Wasm loading rules.

## Native distribution

`zig build package` creates the starter's local `zig-out/bin/seed-sprint` and
`zig-out/assets/` layout. The Peas release scripts additionally prepare
versioned Linux tarballs, macOS universal ZIP layouts, and web directories.
They do not create signed `.app` bundles, DMGs, AppImages, deb/rpm packages,
or installers.

## Platform status

| Target | Intended support | Build/package evidence | Runtime evidence |
| --- | --- | --- | --- |
| Linux x86_64 under WSL2 | development environment, not a deployment target | local package checks | WSLg SDL GPU and OpenGL bounded smoke only |
| Native Linux x86_64 | Tier 1 | CI package matrix | not run in this checkout's WSL pass |
| macOS arm64 / x86_64 | Tier 1 | CI universal package matrix | not run in this checkout's WSL pass |
| Browser/WASM | supported | headless browser/runtime and bundle checks | browser not launched locally |
| Windows x86_64 | secondary | CI package matrix | not run locally |

See the [capability matrix](capabilities.md) for renderer-specific detail.

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
