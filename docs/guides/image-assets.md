# Authored image and font assets

For a small game that wants one synchronous native-and-browser asset path,
embed ordinary authored files at compile time and decode them during
`Game.init`. This avoids filesystem roots, browser fetches, and
platform-specific game code.

Keep source assets in the ordinary project layout:

```text
game/
├── embedded_assets.zig
├── src/game.zig
└── assets/
    ├── player.png
    └── ui.ttf
```

When the application's root source is under `src/`, put the small
`@embedFile` wrapper at the package root so its asset paths are hermetic:

```zig
// embedded_assets.zig
pub const player_png = @embedFile("assets/player.png");
pub const ui_ttf = @embedFile("assets/ui.ttf");
```

Import that project-local module from `build.zig` as `game-assets` alongside
the normal Peas package import:

```zig
const game_assets = b.createModule(.{
    .root_source_file = b.path("embedded_assets.zig"),
    .target = target,
    .optimize = optimize,
});
// Add this entry to the root module's existing imports.
.{ .name = "game-assets", .module = game_assets },
```

Then use the same bytes on every target:

```zig
const up = @import("unpolished-peas");
const art = @import("game-assets");

var image = try up.assets.Image.decode(allocator, art.player_png, .{});
defer image.deinit();

var font = try up.assets.Font.decodeTrueType(allocator, art.ui_ttf, .{
    .pixel_height = 16,
    .atlas_width = 256,
    .atlas_height = 256,
});
defer font.deinit();
```

`Image.decode` accepts PNG, JPEG, and TGA and returns top-left-origin RGBA8
pixels. TGA is limited to true-colour, uncompressed type-2 files with no
colour map and 24- or 32-bit pixels. `Font.decodeTrueType` rasterizes a
single-face authored TrueType/OpenType face into a CPU atlas for
`Font.drawText`.

Both values own allocator-backed decoded data. The embedded byte slices are
static and borrowed; decoded `Image` and `Font` values must be deinitialized
after any `Atlas` or draw use borrowing them has ended. Decode and font
rasterization belong in initialization or an explicit loading phase, never in
the update or draw hot path.

The same stb image and TrueType rasterization path is compiled for native,
headless, and freestanding browser/Wasm builds. There is no JavaScript asset
fetch or asynchronous initialization in this workflow. Fixed source bytes
produce exact decoded image pixels on those targets. Font atlases also share
the same rasterizer; application-side floating-point layout and renderer
presentation are still separate cross-platform concerns.

Image input is bounded before decoded allocation: source bytes are at most 32
MiB, each dimension is at most 4096 pixels, and an image has at most
16,777,216 pixels. Font source is likewise limited to 32 MiB; its glyph count
and atlas dimensions are bounded before allocation. Image decode reports
`UnsupportedImageFormat`, `InvalidImage`, `ImageInputTooLarge`,
`InvalidImageSize`, or `ImageTooLarge`. Invalid font bytes report
`InvalidFontData`, oversized input reports `FontInputTooLarge`, and invalid or
excessive atlas options report their documented font errors.

## Embedded files versus `AssetStore`

Embedding is the portable default for small sprites and fonts. It does not
require an `assets/` directory in a native package at runtime. Peas hosts now
start with an embedding-only `AssetStore` when neither `UP_ASSET_ROOT` nor an
installed `assets/` directory is present.

`AssetStore` remains the explicit runtime-file workflow for replaceable or
larger content. Configure an asset root before calling its loading methods;
an embedding-only store rejects runtime loads with
`error.AssetStoreUnavailable` rather than reading an accidental working
directory. It is not a browser asset fetch API.

This guide deliberately does not add an asset database, manifest, packer,
atlas generator, hot reload system, or general filesystem interface.
