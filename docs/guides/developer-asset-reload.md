# Development authored-asset reload

This is a deliberately narrow **native developer-only** workflow for a game
that embeds authored images and fonts in release builds. It is not an asset
pipeline, a runtime filesystem API, or deterministic game input.

## Enable

Give the SDL host an explicit absolute source directory while developer tools
are enabled. There is no working-directory fallback:

```sh
UP_DEVELOPER_TOOLS=1 \
UP_DEVELOPER_ASSET_ROOT="$PWD/dogfood/neon-siege/assets" \
zig build run-dogfood
```

The source root is separate from `UP_ASSET_ROOT`, which remains the explicit
runtime `AssetStore` location. An embedding-only release package has no
dependency on either directory.

## Register during native game initialization

The experimental helper is exposed by the native host module, not the frozen
`unpolished-peas` root API. Keep registration in a native wrapper around the
shared game so browser game code remains unchanged:

```zig
const sdl = @import("unpolished-peas-sdl3");

pub fn init(self: *@This(), ctx: *GameContext) !void {
    try self.state.init(ctx); // normal embedded Image / Font setup
    if (self.state.atlas) |atlas|
        _ = try sdl.developer.registerAtlasImage(atlas, "player.png", .{});
    if (self.state.font) |font|
        _ = try sdl.developer.registerFont(font, "ui.ttf", .{
            .pixel_height = 16,
            .atlas_width = 256,
            .atlas_height = 256,
        });
}
```

Without an enabled developer source root these calls succeed as no-ops. The
host makes the registry available only while `Game.init` runs, then polls its
explicit registrations at most every 250 ms before the next fixed-update
sequence. It never polls during a fixed update or `Game.draw`.

## Supported sources and behavior

The current scope is intentionally small:

- `Atlas`-owned images decoded through the normal PNG/JPEG/TGA `Image.decode`;
- TrueType/OpenType fonts decoded through the normal `Font.decodeTrueType`.

The source key is relative to the configured developer root and rejects
absolute paths and lexical escapes. Metadata polling uses modification time
and size, waits for a signature to be stable across two polls, and handles
editor-style temporary-file replacement/rename saves.

On a valid change Peas reads and decodes a new complete resource, verifies an
atlas image still covers its registered frames, swaps it at the safe host
boundary, then releases the old value. An invalid save leaves the old live
resource in place, emits a local reload failure, and retries when a new file
signature appears. Developer overlays, the local log, and the optional
developer diagnostics JSON expose bounded reload status.

Short-WAV reload is intentionally not included: the high-level `Audio`
service promises stable game handles for its entire host lifetime, so changing
that ownership contract is outside this development-only pass.

## Release, browser, and determinism

Release builds still use `@embedFile` bytes decoded at initialization. They do
not poll, read developer source files, allocate a reload registry, or require
an asset source tree. Browser/Wasm builds likewise retain the embedded path;
rebuild the browser bundle after changing an authored asset.

Reload events are not replay data, save data, or simulation input. With reload
disabled, the same seed, replay, and embedded assets retain the usual
headless state, Canvas-trace, and pixel-hash determinism. With reload enabled,
editing a source file deliberately changes only live development resource
output.

## Limits

There is no recursive scanner, manifest, watcher thread, background decoder,
browser dev server, generic dependency graph, or arbitrary filesystem access.
Small explicitly registered authored resources are the target; a large decode
can hitch one developer presentation frame.
