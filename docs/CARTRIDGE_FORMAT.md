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

## Cartridge PNG and presentation identity

`.pxc.png` is a deterministic 320x240 RGBA PNG depicting PX-240C's own sloped-shell cartridge
object and label, not another fantasy console's silhouette. A required private `pxCa` ancillary
chunk contains the byte-exact canonical `.pxc`; a required `pxCm` chunk contains bounded canonical
JSON title, author, year, player-count, and control metadata. Both normal PNG chunk CRCs and the
inner canonical cartridge hashes are checked before project reconstruction. Exactly one payload and
metadata chunk are required. Studio accepts raw `.pxc` and `.pxc.png`; `px240c export png PROJECT
--output FILE` writes the image and `px240c info FILE.pxc.png` inspects its embedded cartridge.

The image pixels are presentation only. Import always reconstructs source and assets from `pxCa`,
so label capture and image conversion cannot change program identity. Studio uses the most recent
240x144 run frame for the label when available, otherwise its fixed factory screen. Project settings
store optional `presentation/cartridge.json`; label PNG import is strictly 240x144.

## Standalone HTML

`px240c export html` and the Studio `export` command call the same Rust exporter. It first packs and
decodes the project, then embeds the verified canonical bytes, manifest and every archive entry as
base64 inside one HTML file. The inline revision-1 host uses no CDN, backend, or external asset
request; its generated Worker is the production `sandbox-worker.ts`/`console-runtime.ts`, not a
second emulator. The visible `SOURCE` inspector decodes every original `source/` module. Indexed
graphics, raster state, synth/tracker PCM, four gamepad ports, keyboard and pointer/touch input,
work limits and byte saves therefore have the same semantics as Studio. Saves use a cartridge-ID
scoped V1 key and migrate the prior standalone integer-JSON key without cross-cartridge access.

The player publishes `px240c-format`, `px240c-embed`, `px240c-players`, and `px240c-controls` metadata
and displays title, author, year, player count, and controls. Pause stops frame/input time and closes
the host audio queue; reset constructs a fresh production Worker while retaining the isolated save;
fullscreen and source inspection are explicit controls. Loading the same file with `#embed` removes
the outer product chrome but retains all controls, metadata, source, and deterministic output.

`px240c export zip` and Studio `EXPORT ZIP` wrap that exact HTML byte sequence as `index.html` in a
deterministic stored ZIP. The archive uses no timestamps, comments, paths, compression variability,
or external files and is ready for itch.io's HTML upload mode.

## Tiny URL fragments

Studio `SHARE` is intentionally secondary to file export. It accepts only complete canonical carts
at or below 6,000 bytes and emits base64url bytes after `#pxc=`. The entire fragment is limited to
8,192 characters, is displayed before copying, contains no query parameter, and by URL semantics is
never included in HTTP requests. On boot Studio validates the encoding, byte limit, canonical
cartridge, manifest, paths, source, and assets before saving a recovery-backed local project. Invalid
fragments report an error without preventing the local Studio from booting.

## Headless traces

`px240c run PROJECT_OR_PXC --headless` recompiles source through the authoritative Rust compiler and
drives the production TypeScript core without opening a browser. `--seed`, `--frames`, `--input`,
`--save` and `--output` control a run. Input JSON revision 1 contains sorted, non-overlapping frame
records with a starting `frame`, optional `duration`, and up to four `{port, buttons}` assignments;
an optional complete pointer record supplies `x`, `y`, `primary`, `secondary` and `inside`.

The revision-1 JSON result includes every frame's framebuffer, state, audio-command, little-endian
Float32 PCM and committed-save SHA-256 plus work use. Its summary reports final hashes, aggregate
audio/PCM hashes, completed/requested frames, peak work and any stable PX9xxx fault/span. Requests
are bounded to 36,000 frames, 8 MiB of trace JSON, 2 MiB of decoded files, 256 KiB of ROM and 8 KiB
of save data. A modeled cartridge fault is a successful trace result; malformed input or a host
failure exits unsuccessfully.

The same revision-1 trace is the `.pxrec` interchange form. Studio records exact four-port and
pointer input, compacts adjacent identical frames with `duration`, exports canonical JSON, and can
restart the active cartridge from an imported trace. Import is UTF-8/schema/count/range validated
before the Worker receives any input.

## Reproducibility

For identical manifest, source, asset bytes, and compiler revision, `px240c pack` emits identical
bytes. The CLI integration suite builds two artifacts and byte-compares them; core tests also prove
LF/CRLF normalization and bounded malformed-input handling. Standalone exports are likewise
byte-identical for identical inputs.
