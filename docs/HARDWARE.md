# Experimental alpha hardware profile

These values are centrally defined experimental limits. They are not final until all three pack-in
cartridges have been measured and the calibration milestone freezes the profile.

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
| Controller ports                |                      4 |

Framebuffer storage is double-buffered and separate from visual assets. Sprites may be 1-64 pixels
per axis; sprites, animation frames, 8x8 tiles, maps, fonts, and raster data share visual capacity.
One colour index is transparent. Scaling and rotation use deterministic nearest-neighbour sampling.
No operation exposes arbitrary alpha, bilinear filtering, imported samples, or true-colour output.

## Synthetic work model

Work units are deterministic accounting units, not real CPU instructions and not evidence for a
fictional clock speed. The compiler currently charges 8 units at each function/callback entry, 4 at
loop back-edges, 4 per task-state transition, 4 per allocation, and 2 before each console API call.
The runtime adds facility-specific costs as graphics and audio implementations land. Charges retain
source spans for profiler attribution and budget faults.

The per-frame work-unit ceiling is intentionally not frozen yet. It will be selected from measured
platformer, roguelike, single-player racer, and four-player split-screen frame distributions. The
runtime already requires a positive fixed limit for each cartridge execution and stops the frame at
the first charge that exceeds it.
