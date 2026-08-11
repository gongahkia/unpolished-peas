# Portable asset loaders

`engine/assets` manages typed values from a project-relative `fs.FS`. The
standard decoders return engine-owned data and never expose an image, font,
audio, or tile-map backend handle.

## Supported source formats

| Asset | Loader | Output | Supported input |
| --- | --- | --- | --- |
| Image | `assets.DecodeImage` | `render.Image` | PNG, JPEG, GIF; decoded to copied, non-premultiplied RGBA8 pixels |
| Font | `assets.DecodeFont` | `assets.Font` | validated TrueType/OpenType SFNT data |
| Audio | `assets.DecodeWAV` | `assets.Sound` | RIFF/WAVE PCM 8/16/24/32-bit and IEEE float32 samples |
| Tile map | `assets.DecodeTileMap` | `assets.TileMap` | the JSON format below |

Each loader consumes at most 64 MiB of encoded data. Images are additionally
limited to 16,777,216 pixels before conversion to RGBA8. These limits are
validation boundaries, not a streaming asset format; larger assets need an
explicit future design instead of silently allocating unbounded memory.

## Loading and ownership

```go
manager := assets.NewManager(projectFiles)
textureSource, err := assets.Load(manager, "art/tiles.png", assets.DecodeImage)
font, err := assets.Load(manager, "fonts/ui.ttf", assets.DecodeFont)
sound, err := assets.Load(manager, "audio/jump.wav", assets.DecodeWAV)
tiles, err := assets.LoadTileMap(manager, "maps/first.tiles.json", textureSource)
```

The variables above are typed asset handles. Use `assets.Get` to retrieve the
current value and `assets.Reload` when the project filesystem changes. Image
pixels, font bytes, WAV samples, JSON tile values, and render-command tile
slices are copied at their ownership boundaries. A caller must not retain an
input reader after a loader returns.

`assets.Sound.Audio` returns a copied `audio.Sound` suitable for `Mixer.Play`.
`LoadTileMap` records the supplied image handle as a manifest dependency. For
other asset relationships, use `assets.SetDependencies`. `Manager.Manifest` is
stable by asset ID and reports the source path, Go type, and dependency IDs used
by the packaging workflow.

## Tile-map JSON

```json
{
  "texture": "art/tiles.png",
  "width": 40,
  "height": 23,
  "atlasWidth": 256,
  "atlasHeight": 256,
  "tileWidth": 16,
  "tileHeight": 16,
  "tiles": [0, 1, -1]
}
```

`texture` must be a project-relative path. The atlas dimensions must divide
evenly by tile dimensions, `tiles` must contain exactly `width * height` row-
major entries, and each entry is either `-1` for an empty cell or a valid
row-major atlas index. `TileMap.Render` combines a validated map with a
backend-neutral `render.Texture` handle and origin to produce the public
`render.TileMap` command payload.

## Error behavior and unsupported inputs

Loader errors name the source asset and decoding operation. Invalid paths,
malformed headers, unsupported WAV encodings, inconsistent WAV frame
alignment, malformed font tables, JSON fields outside the tile-map contract,
invalid atlas indices, and missing manifest dependencies fail at load time.

MP3, Ogg, FLAC, animated image playback, variable-size tile layers, Tiled TMX,
sprite packing, font rasterization, and source-art conversion are not currently
supported. A platform audio or graphics library must not be used as an
undeclared fallback decoder.
