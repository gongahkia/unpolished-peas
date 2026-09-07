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

## Synthetic work model

Work units are deterministic accounting units, not real CPU instructions and not evidence for a
fictional clock speed. The compiler currently charges 8 units at each function/callback entry, 4 at
loop back-edges, 4 per task-state transition, 4 per allocation, and 2 before each console API call.
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
simultaneous views at about 31,422 units, leaving headroom for input-dependent variation while still
making the limit visible during ordinary development.
