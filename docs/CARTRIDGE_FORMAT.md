# PX-240C cartridge format

PX-240C revision 1 has a Git-friendly authoring tree and a deterministic single-file `.pxc`
representation. The Rust core is authoritative; malformed or non-canonical archives are rejected.

## Project tree and manifest

A project contains `cart.toml`, one or more ASCII `.pxl` modules, and any explicitly named asset,
label, or thumbnail files. A minimal manifest is:

```toml
format = 1
language = "PXCL/1"
id = "author.game"
title = "GAME TITLE"
author = "@gongahkia"
version = "0.1.0"
entry = "src/main.pxl"
update_rate = 60
display = "assets/display.pxp"

[assets.hero]
kind = "sprite"
path = "assets/hero.pxg"
```

`update_rate` is 30 or 60. Optional `label`, `thumbnail`, and `display` keys name project-relative
files. `display` selects the default palette/raster state described in [ASSETS.md](ASSETS.md).
Asset kinds are `sprite`, `animation`, `tile_set`, `map`, `sound`, `music`, and `font`. IDs contain 3-64
lowercase ASCII letters, digits, dots, or hyphens. Paths are relative ASCII paths; empty segments,
`.`/`..`, backslashes, and absolute paths are invalid. Unknown manifest fields are errors.

Imports are absolute dotted module paths: `import src.math as math` resolves `src/math.pxl`.
Reachable imports are linked in dependency order. Import cycles, dependency modules with system
callbacks, unknown members, and colliding top-level names are errors in revision 1.

## Canonical `.pxc` bytes

All integers are little-endian. The file begins with the eight bytes `PX240C 1A 01`, followed by a
`u32` entry count. Entries are strictly sorted by their archive path and have this shape:

| Field          | Encoding                                     |
| -------------- | -------------------------------------------- |
| path length    | `u16`                                        |
| raw length     | `u32`                                        |
| encoded length | `u32`                                        |
| integrity      | 32 raw SHA-256 bytes over decoded entry data |
| path           | canonical ASCII bytes                        |
| payload        | canonical PackBits-style RLE bytes           |

RLE packets encode 1-128 bytes. A high tag bit denotes a repeated-byte packet; otherwise the packet
is literal. Runs of four or more bytes use repeated packets. The decoder re-encodes every payload
and rejects alternate encodings, so equivalent data has one representation.

The archive contains normalized `source/` modules, `assets/` data, optional `presentation/` files,
`build/cartridge.js`, `build/cartridge.js.map`, and compact canonical `manifest.json`. Source line
endings are normalized to LF. The manifest records compiler/language/format revisions and a sorted
size/SHA-256 inventory for every other entry. There are no timestamps, permissions, host paths, or
platform metadata.

Packed size is limited to 256 KiB. Decoding additionally limits expansion to 2 MiB and 4,096
entries, checks every length and hash, rejects trailing bytes, and verifies the manifest inventory.
`px240c pack` performs a decode after encoding before it writes the artifact.

Validated cartridges can be reconstructed into their source-visible project form. Import reverses
the `source/`, `assets/`, and `presentation/` prefixes, regenerates a validated `cart.toml`, and
never exposes compiled build entries as editable source.

## Standalone HTML

`px240c export html` and the Studio `export` command call the same Rust exporter. It first packs and
decodes the project, then embeds the verified canonical manifest and every archive entry as base64
inside one HTML file. The inline revision-1 runtime uses no CDN, backend, or external asset request;
the visible `SOURCE` inspector decodes and displays every original `source/` module. The player
retains indexed graphics, raster state, synth/tracker audio, four gamepad ports, keyboard and
pointer/touch input, deterministic work limits, and a cartridge-ID-scoped browser save key.

## Reproducibility

For identical manifest, source, asset bytes, and compiler revision, `px240c pack` emits identical
bytes. The CLI integration suite builds two artifacts and byte-compares them; core tests also prove
LF/CRLF normalization and bounded malformed-input handling. Standalone exports are likewise
byte-identical for identical inputs.
