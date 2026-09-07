# PX-240C asset files

Project assets are UTF-8 JSON with a trailing newline. They remain readable in a project directory
and inside a `.pxc`; the Studio editors write the same revision-1 representation documented here.
Manifest names, rather than filenames, become typed PXCL handles such as `#hero` and `#theme`.

Every file has `"revision": 1` and a `kind`. Indexed colour values are integers from 0 through 31.
Colour 0 is transparent when a sprite is blitted. The fixed master RGB palette itself is not stored
in a cartridge and cannot be replaced.

## Graphics

A `sprite` file contains a 1-64 pixel width and height and one or more row-major frames. Declare a
single-frame file as `sprite` or a multi-frame file as `animation` in `cart.toml`:

```json
{ "revision": 1, "kind": "sprite", "width": 2, "height": 2, "frames": [[0, 23, 23, 0]] }
```

A `tile_set` contains 8x8 row-major tiles and one eight-bit flag value per tile:

```json
{
  "revision": 1,
  "kind": "tile_set",
  "tiles": [
    [
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1
    ]
  ],
  "flags": [1]
}
```

A `map` has 1-8 layers. Each layer has a 1-256 cell width and height, row-major unsigned tile
indices, and the manifest name of its tile set:

```json
{
  "revision": 1,
  "kind": "map",
  "layers": [{ "width": 2, "height": 1, "cells": [0, 0], "tileSet": "tiles" }]
}
```

Sprite pixels, animation pixels, tile pixels and flags, two bytes per map cell, and display state
share the 128 KiB visual capacity. The loader rejects missing tile sets and out-of-range tile
indices before execution.

## Display state

The optional top-level `display = "assets/display.pxp"` manifest key names a default palette and
raster configuration. `remap` sets the initial logical drawing palette. Raster rows are strictly
increasing scanline changes with signed 16-bit scroll offsets and a complete 32-entry display
remap:

```json
{
  "revision": 1,
  "kind": "display",
  "remap": [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27, 28, 29, 30, 31
  ],
  "raster": [
    {
      "line": 96,
      "scrollX": 0,
      "scrollY": 0,
      "remap": [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
        25, 26, 27, 28, 29, 30, 31
      ]
    }
  ]
}
```

PXCL `pal`, `pal_reset`, and `on raster` commands may override these defaults while a cartridge is
running. Display state is charged as 32 bytes plus 38 bytes per raster row.

## Synth patches and tracker music

A `sound` is an oscillator patch. Notes are MIDI integers 0-127, duration and envelope time are in
frames, volume and sustain are 0-1, and pan is -1 to 1. Pulse duty must be between zero and one.
Wavetables contain 4-32 samples in the range -1 to 1.

```json
{
  "revision": 1,
  "kind": "sound",
  "waveform": "pulse",
  "note": 60,
  "durationFrames": 18,
  "volume": 0.6,
  "pan": 0,
  "duty": 0.5,
  "envelope": { "attackFrames": 1, "decayFrames": 3, "sustainLevel": 0.65, "releaseFrames": 4 },
  "pitch": { "slideSemitonesPerFrame": 0, "vibratoDepthSemitones": 0, "vibratoPeriodFrames": 0 }
}
```

A `music` file supplies an order list and named patterns. Each row has exactly eight cells; a cell
is null or a note naming a declared sound patch. Patterns have 1-256 rows and `framesPerRow` is
1-240.

```json
{
  "revision": 1,
  "kind": "music",
  "framesPerRow": 6,
  "order": ["00"],
  "patterns": {
    "00": { "rows": [[{ "note": 60, "sound": "blip" }, null, null, null, null, null, null, null]] }
  },
  "loop": true
}
```

Arbitrary PCM data is intentionally not representable. Custom `font` assets are reserved by the
manifest schema but are not implemented in revision 1; cartridges use the built-in bitmap font.
