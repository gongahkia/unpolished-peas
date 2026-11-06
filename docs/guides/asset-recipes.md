# Portable asset recipes

Call reference: [collection, image/font/atlas and animation APIs](../api/assets.md)
with source-derived options, lifetimes and the compiled recipe excerpts.

Use embedded bytes and `assets.AssetCollection` for a small game that wants
images, authored fonts, and sprite sheets with one game-owned cleanup boundary.
The same code runs in native, browser, and headless `GameProtocol` hosts.
The collection is optional; directly owned `Image`, `Font`, and `Atlas` values
remain supported when their lifetimes should differ.

The [asset workbench game](../../examples/asset_workbench_game.zig) is the
complete portable example. Its [desktop entry point](../../examples/asset_workbench.zig)
only supplies window configuration and forwards the game callbacks.

```sh
zig build run-asset-workbench
zig build web-asset-workbench -Dwith_sdl=false
python3 -m http.server --directory zig-out/asset-workbench 8000
```

Open `http://localhost:8000`. Arrows move an animated sprite; Space plays a
sound and increments a persisted score. The full image and authored-font
caption use the same resources on both hosts.

## One owner, stable borrowed resources

Keep an optional collection and the borrowed resources in ordinary game state:

```zig
assets: ?up.assets.AssetCollection = null,
image: ?*const up.assets.Image = null,
font: ?*const up.assets.Font = null,
sheet: ?*const up.assets.Atlas = null,
```

Initialize the collection before the first fallible load. A protocol host does
not call `Game.deinit` when `Game.init` fails, so use one error cleanup covering
all successful loads:

```zig
pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
    self.assets = up.assets.AssetCollection.init(try ctx.requireAllocator());
    errdefer self.deinit(ctx) catch {};
    self.image = try self.assets.?.image(art.player_png, .{});
    self.font = try self.assets.?.font(art.ui_ttf, .{ .pixel_height = 12 });
    self.sheet = try self.assets.?.atlas(art.sheet_png, &frames, .{});
}

pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
    if (self.assets) |*assets| assets.deinit();
    self.assets = null;
    self.image = null;
    self.font = null;
    self.sheet = null;
}
```

Loads decode synchronously and copy their decoded data and Atlas metadata.
Encoded bytes are borrowed only during the call; they need not outlive the
collection. Each successful load returns a stable pointer even as
later loads grow the collection. A failed load releases its own allocations
and leaves earlier resources usable. Cleanup releases all resources in reverse
load order. Do not deinitialize returned resources individually or copy a live
collection into two owners. Moving its sole owner is safe; the resources do
not point into the collection's struct or registry storage.

Draw using the existing APIs; the collection adds no rendering model:

```zig
canvas.drawImage(self.image.?.*, 20, 40);
self.font.?.drawText(canvas, "Peas 42", 8, 8, up.core.Color.white);
canvas.drawAtlasFrame(self.sheet.?.*, player.currentFrame(), 80, 34, .{});
```

The collection has no name registry, caching, deduplication, implicit global
state, individual unload, or automatic native hot reload. Load during init or
an explicit loading phase. Per-resource decode limits and errors are unchanged;
the game chooses its total memory budget and lifetime. For independent resource
release, keep the existing lower-level ownership
APIs. Native file loading and developer reload keep their separate explicit
configuration; the collection does not locate files or register reload sources.

## Task reference and compiled recipes

All five recipes are compiled and exercised in
[`examples/asset_recipes.zig`](../../examples/asset_recipes.zig):

| Task | Public calls | Ownership / timing |
| --- | --- | --- |
| Image | `collection.image(bytes, ImageDecodeOptions)` → `!*Image`; `canvas.drawImage(image.*, x, y)` | Decode once; borrow until collection cleanup. |
| Authored font | `collection.font(bytes, FontLoadOptions)` → `!*Font`; `font.drawText(canvas, text, x, y, color)` | Decode/rasterize once. Font glyph coverage and shaping limits still apply. |
| Sprite animation | `collection.atlas(bytes, frames, Atlas.DecodeOptions)` → `!*Atlas`; `clip.validateForAtlas(atlas)`; `SpriteAnimationPlayer.init(&clip)` | Sheet pixels and metadata belong to the collection. Clips and player state remain game-owned. Advance only in fixed updates. |
| Sound | `loadEffect(ctx)` and `playEffect(ctx, handle)` recipes use `ctx.audio.loadWav` / `play` | Audio host owns the loaded sound until host teardown. Collection cleanup does not unload it. Browser activation/device failures remain recoverable. |
| Progress | `loadProgress(ctx)` and `saveProgress(ctx, score)` recipes use `ctx.save_data.read` / `write` | Four explicit little-endian bytes, with missing/unavailable/corrupt data handled by the game. No raw struct serialization. |

`Atlas.DecodeOptions` contains `image: ImageDecodeOptions = .{}`,
`image_path: []const u8 = "embedded"` (metadata only), and
`animations: []const AtlasAnimationSpec = &.{}`. Ordinary deterministic
animation uses static `SpriteAnimationClip` steps; legacy Atlas animation
metadata remains optional and supported. Font/image options retain their
existing defaults. See [images/fonts](image-assets.md),
[sprite animation](sprite-animation.md), [audio](audio-assets.md), and
[saves](save-data.md) for bounds and error behavior.

## Before and after

The reference games formerly repeated this successful-load setup for a sheet
and font (excerpt from Neon Siege before collection adoption):

```zig
const image = try up.assets.Image.decode(allocator, art.sprite_sheet_png, .{});
const atlas = try allocator.create(up.assets.Atlas);
errdefer allocator.destroy(atlas);
atlas.* = try up.assets.Atlas.init(allocator, image, "neon-siege.png", &art.frames, &.{});
self.atlas = atlas;
const font = try allocator.create(up.assets.Font);
errdefer allocator.destroy(font);
font.* = try up.assets.Font.decodeTrueType(allocator, art.ui_font_ttf, options);
self.font = font;
```

They also stored the allocator and separately called `atlas.deinit`,
`allocator.destroy(atlas)`, `font.deinit`, and `allocator.destroy(font)`.
That old excerpt left some early failure cases uncovered; it is a comparison,
not a recommended error-handling recipe.

Both [Neon Siege](../../dogfood/neon-siege/src/game.zig) and
[Lantern Leap](../../dogfood/lantern-leap/src/game.zig) now load through:

```zig
const atlas = try self.assets.?.atlas(art.sprite_sheet_png, &art.frames, .{});
self.atlas = atlas;
self.font = try self.assets.?.font(art.ui_font_ttf, options);
```

One collection cleanup replaces all four per-object cleanup operations. Their
asset-only allocator field and explicit Atlas/Font object allocations disappear.
Their other resources (ActionMap and RenderSurface) keep their existing owners.
Frame lookup, clips, fixed updates, and drawing calls are unchanged. Existing
pixel/replay goldens verify that this ownership change preserves their output.

For a single independent image, direct `Image.decode` plus `image.deinit` is
already short; the collection's benefit grows with several related resources.
It adds a small object allocation per resource and a registry allocation to
provide stable pointers. It does not reduce rasterization or draw cost.

## Asset paths and remaining build configuration

The simplest new-game layout keeps encoded assets inside the game module root:

```text
src/
  game.zig
  assets/player.png
  assets/ui.ttf
```

Then `@embedFile("assets/player.png")` and `@embedFile("assets/ui.ttf")`
work directly from `game.zig`; no extra asset module or build imports are
needed. A generated starter's existing root `assets/` directory is for its
runtime-file/package layout. Put portable embedded content under `src/assets/`
or explicitly configure the root-level wrapper described in
[images/fonts](image-assets.md). Zig's module-root restriction is unchanged.
Both native and browser builds still need their normal Peas imports and game
module configuration. Distribute the asset authors' applicable notices too;
embedding a font does not remove its notice obligations.

## Validation

```sh
zig build test-asset-workbench -Dwith_sdl=false
zig build test-browser-asset-collection -Dwith_sdl=false
zig build test-asset-collection-consumer -Dwith_sdl=false
script/test_browser_asset_workbench.sh
```

The headless suite exercises every Zig allocation failure during game init,
including font rasterization and collection registration, as well as
cleanup, pointer stability, invalid metadata, replay pixels, audio ownership,
and progress reload. The Wasm check compares the same scripted game's exact
pixels and saves against a native run across three complete lifecycles.
The consumer test builds outside the checkout against an actual source archive
served over loopback HTTP with its computed Zig package hash; it executes
`zig build`, `zig build test`, `zig build web`, and `zig build package`.
The real Chromium check covers rendering, input-driven saving, restart, and
teardown. Physical audio-device quality and every desktop/browser combination
remain separate platform validation tasks.

### Verified November 5, 2026

Executed with Zig 0.15.2 on Intel macOS:

```sh
zig build test test-core-api test-support test-replays test-starter \
  test-starter-template test-dogfood test-lantern-leap test-docs docs \
  test-browser-authored-assets test-browser-asset-collection \
  -Dwith_sdl=false --summary all
zig build check-examples --summary all
zig build test-sdl run-asset-workbench --summary all -- --frames 2
zig build web-asset-workbench test-browser-image-assets test-audio \
  test-browser-audio -Dwith_sdl=false --summary all
zig build test-asset-collection-consumer -Dwith_sdl=false --summary all
script/test_browser_asset_workbench.sh
zig fmt --check build.zig src examples templates dogfood
git diff --check
actionlint .github/workflows/toolchain.yml
sh -n script/test_browser_asset_workbench.sh
```

Results: the combined portable suite passed 69/69 steps and 386/386 tests;
all 40 example build steps succeeded; the SDL suite passed 63/63 tests; the
additional browser/audio suite passed 15/15 steps and 2/2 tests. The native
example launched with Cocoa, SDL GPU/Metal, and audio ready. Native and Wasm
scripted-game pixels matched exactly (`14213088955867194127`), with score 2
and saved progress 2 across three Wasm lifecycles. Existing image/font and
reference-game goldens were retained. Real Chromium rendering, save/restart,
and teardown checks passed. The external archive consumer passed all four
commands above, including a test of the generated wrapper's cleanup forwarding.

Allocation-failure testing also exposed and fixed a duplicate pixel-buffer
free in the existing font decoder. The new Atlas byte constructor cleans up
all decode/metadata failures; the existing `Atlas.init` API retains its behavior.
No README files were changed. These results do not claim a new interactive
Windows/Linux, Apple Silicon, Firefox, or Safari hardware validation run.
