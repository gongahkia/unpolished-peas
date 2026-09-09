# Frozen alpha hardware profile

These centrally defined revision-1 limits were frozen after measuring all three bundled cartridges.
See [LIMITS.md](LIMITS.md) for the calibration evidence.

| Facility                        |          Current value |
| ------------------------------- | ---------------------: |
| Display                         | 240x144 indexed pixels |
| Render cadence                  |                  60 Hz |
| Update cadence                  |            30 or 60 Hz |
| Master palette                  |       32 fixed colours |
| Visual asset capacity           |                128 KiB |
| Cartridge capacity              |                256 KiB |
| Cartridge save block            |                  8 KiB |
| Draw commands                   |        4,096 per frame |
| Synth voices / tracker channels |                  8 / 8 |
| Synth output                    |       48,000 Hz stereo |
| Controller ports                |                      4 |
| Work units                      |       50,000 per frame |

Framebuffer storage is double-buffered and separate from visual assets. Sprites may be 1-64 pixels
per axis; sprites, animation frames, 8x8 tiles, maps, fonts, and raster data share visual capacity.
One colour index is transparent. Scaling and rotation use deterministic nearest-neighbour sampling.
No operation exposes arbitrary alpha, bilinear filtering, imported samples, or true-colour output.

## Fixed master palette

The RGB values below are original to PX-240C. Authors can remap logical indices while drawing and
during scanout but cannot change these values.

| Index | RGB       | Index | RGB       | Index | RGB       | Index | RGB       |
| ----: | :-------- | ----: | :-------- | ----: | :-------- | ----: | :-------- |
|     0 | `#17141f` |     8 | `#5b2938` |    16 | `#263c32` |    24 | `#243451` |
|     1 | `#292532` |     9 | `#8b3c47` |    17 | `#345f46` |    25 | `#345581` |
|     2 | `#403946` |    10 | `#bf5558` |    18 | `#4b8b58` |    26 | `#4b7db3` |
|     3 | `#5d5054` |    11 | `#ed7b69` |    19 | `#7fbd68` |    27 | `#73a9d1` |
|     4 | `#806a63` |    12 | `#5a3928` |    20 | `#203b47` |    28 | `#3e3154` |
|     5 | `#aa8b74` |    13 | `#89572e` |    21 | `#2e6571` |    29 | `#654777` |
|     6 | `#d5b992` |    14 | `#c18436` |    22 | `#43969a` |    30 | `#936397` |
|     7 | `#f4e5bd` |    15 | `#e7bd50` |    23 | `#75cbc0` |    31 | `#c38aae` |

## V1 candidate byte bus (in progress)

The Worker-owned production core now exposes the following **implemented subset**, not the finished
Hardware Revision 1 contract. Visual allocations/descriptors, input, audio, time/RNG/work/faults,
save commits and cartridge ROM registers remain to be mapped. The standalone exporter still uses its
alpha runtime and does **not** support these new calls yet. Do not use this checkpoint to claim V1
hardware conformance or standalone parity.

The candidate address space is 22 bits: `0x000000` through `0x3fffff` (4 MiB of addresses, not 4 MiB
of work RAM). It leaves room for cartridge descriptors without taking bytes from the fixed 128 KiB
visual capacity. There are no address wraps or mirrored mappings. Every currently unmapped address
reads zero; writing one faults. Offsets below are hexadecimal; lengths and counts are decimal.

| Address |  Bytes | Access | Actual backing state / reset                                                                                        |
| :------ | -----: | :----- | :------------------------------------------------------------------------------------------------------------------ |
| `00000` | 65,536 | RW     | Work RAM, zero on cartridge load.                                                                                   |
| `10000` | 34,560 | RW     | Front indexed framebuffer; zero before `on start`.                                                                  |
| `19000` | 34,560 | RW     | Back indexed framebuffer; zero before `on start`.                                                                   |
| `22000` | 34,560 | R      | Resolved indexed scanout; zero before `on start`.                                                                   |
| `50000` |     80 | RW     | Draw camera/clip and logical palette remap; layout below.                                                           |
| `50050` |      1 | R      | Actual sprite transparency index, fixed at zero.                                                                    |
| `50080` |    128 | R      | Immutable master palette, 32 RGBA byte tuples; alpha always 255.                                                    |
| `50400` |     48 | R      | Raster callback accumulator: two little-endian binary64 scroll values and 32 remap bytes. Reset `(0,0)` / identity. |
| `55000` |  5,760 | RW     | 144 scanline records, 40 bytes each; layout below.                                                                  |

All framebuffer bytes must be indices 0–31. Raw writes bypass draw camera, clip and logical remap;
they do not bypass scanout remapping. `on start` now executes both high-level drawing and bus writes
against the same back buffer and publishes it once before frame zero. It starts synth commands
without advancing audio time. Alpha discarded start-time draw/audio commands; preserving them is the
explicit V1 boot semantic required for coherent mixed access. The three original game traces remain
the compatibility boundary for their actual behavior.

At each display frame's beginning, back receives front; draw state, raster records and the callback
accumulator reset to the cartridge display defaults. Drawing and bus writes then occur in program
order. Scanout reads back through the raster table after all 144 callbacks, publishes resolved pixels,
and copies back to front without changing either buffer's address. A front-only write during a frame
does not also change back and is overwritten at frame completion. Back writes affect that frame.
RAM persists until a cartridge restart or snapshot restore. Palette RGB/transparency are immutable.

Draw-state offsets from `50000`:

| Offset     | Encoding                    | Meaning / frame reset                                              |
| :--------- | :-------------------------- | :----------------------------------------------------------------- |
| `00`, `08` | little-endian IEEE binary64 | Camera X/Y, zero.                                                  |
| `10`, `18` | little-endian IEEE binary64 | Clip X/Y, zero.                                                    |
| `20`, `28` | little-endian IEEE binary64 | Clip width/height, 240/144.                                        |
| `30`–`4f`  | 32 unsigned bytes           | Logical palette remap, identity or cartridge display-file default. |

The six binary64 fields must remain safe integers; widths/heights must also be nonnegative. This
encoding preserves the existing PXCL `Int` coordinate range instead of silently narrowing old camera
and clip calls. High-level `camera`/`clip`/`pal` access these exact bytes. Low-level code can copy an
entire eight-byte field transactionally from RAM; an intermediate noninteger, infinity or NaN faults.
For example binary64 `2` has word `0x4000` at field offset six and zero in its other three words.

Raster record offsets from `55000 + line*40`:

| Offset     | Encoding                    | Meaning                                              |
| :--------- | :-------------------------- | :--------------------------------------------------- |
| `00`       | unsigned byte 0 or 1        | Whether this line changes the current scanout state. |
| `01`–`03`  | zero bytes                  | Padding; writes must keep these zero.                |
| `04`, `06` | little-endian signed 16-bit | Wrapped scanout X/Y offset.                          |
| `08`–`27`  | 32 unsigned bytes 0–31      | Complete scanout remap.                              |

With no display-file record, enable and all other bytes reset to zero. Disabled records inherit the
last enabled line, initially zero scroll and identity remap. `pal`/`raster_scroll` in a raster callback
update their accumulator and write a **complete** enabled record for that line; callback scroll values
are clamped to signed 16-bit on capture, matching alpha. Direct table writes share that record, with
later writes winning. Reads are allowed during any callback; raster-time writes are restricted to
the raster table. Effects remain bounded by the normal frame work budget.

### Memory operations, faults and snapshots

All arguments/results below are PXCL `Int` except the unit-returning writes. Words are unsigned
little-endian 16-bit and need not be aligned. `mem_copy` uses source bytes as they stood before the
operation, including when source and destination overlap.

| Call                                                  | Runtime work units |
| :---------------------------------------------------- | -----------------: |
| `mem_read(address)` / `mem_write(address, value)`     |                  1 |
| `mem_read16(address)` / `mem_write16(address, value)` |                  2 |
| `mem_copy(destination, source, count)`                |      `1 + 2*count` |
| `mem_fill(destination, byte, count)`                  |        `1 + count` |

The compiler also charges its existing two units per API call. Bus writes are not high-level draw
commands and do not consume that separate 4,096-command allowance. Addresses/counts and unsigned
value width are validated first; work is charged before allocating a bulk staging buffer. Every
destination's permission and resulting register value is checked before any destination changes,
including operations crossing region boundaries. Failed operations retain their charged work.
An empty copy/fill costs one unit and accepts the one-past-end address `0x400000`; no byte is accessed.

`PX9020` denotes an invalid address/range, `PX9021` a reserved/read-only destination, `PX9022` an
invalid byte/word/register value, and `PX9011` a write outside the raster facility during `on raster`.
`PX9001` remains the work-limit fault. All carry the originating PXCL span. Type-invalid source is
rejected by the compiler before execution. New memory built-ins are resolved on first use to retain
old programs' symbol IDs and existing user functions with those names.

Internal core snapshot revision 3 adds RAM and all mutable/retained bus regions. Its existing
framebuffer projection must agree with the memory image. Restore checks region layout and values
before mutation and rolls back device, machine, save and pending-write state on a failure. Revision-2
frame snapshots migrate with zero RAM; raw alpha revision-1 snapshots still restore only their
original machine/save fields. This is frame-boundary compatibility, not public `.pxrec` migration
or source-statement suspension. Full source-level pause state remains required.

`tests/conformance/memory.pxl` runs through the native compiler and shared production core in release
and debug tests, and through Wasm and the actual Worker in Firefox E2E. The lower-level bus tests
cover all mapped regions, all 144 raster rows, mixed high/low writes, reset, permissions, bounds,
unaligned words, overlaps, exact work charges and rollback. These tests cover this subset only.

## Synthetic work model

Work units are deterministic accounting units, not real CPU instructions and not evidence for a
fictional clock speed. The compiler currently charges 8 units at each function/callback entry, 4 at
loop back-edges, 4 per task-state transition, 4 per allocation or fixed-capacity write, one per
materialized range element, and 2 before each console API call. Charging a range before allocation
lets the frame budget reject an extreme dynamic range without first constructing it.
V1 enum payload equality additionally charges one unit per payload slot or traversed nested field;
payload-free enum comparisons keep their existing work cost and survive snapshot cloning.
The runtime charges 1,080 units for `clear`; one for a pixel; `max(abs(dx), abs(dy)) + 1` for a line;
`2*abs(width) + 2*abs(height)` for an outline rectangle; `ceil(abs(width*height)/4)` for a filled
rectangle; `8*abs(radius)` for a circle outline; `ceil(3*radius^2/4)` for a filled circle; and
`ceil(abs(cross-product)/8)` for a filled triangle. A normal sprite/animation costs 32 units, a
transformed sprite costs `max(32, 32*scale^2)`, a map draw costs 128, printed text costs six per
character, and an audio command costs eight. State-only graphics calls cost one. These are simple
deterministic estimates, not timing predictions. Charges retain source spans for profiler attribution
and budget faults.

The per-frame work-unit ceiling is 50,000. The runtime stops at the first charge that exceeds it and
reports the responsible source span. The highest measured bundled path is Raster Rush with four
simultaneous views at about 31,682 units, leaving headroom for input-dependent variation while still
making the limit visible during ordinary development.
