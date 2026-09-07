# PX-240C cartridge API

This reference covers the currently implemented PXCL/1 console surface. Calls are statically typed,
charged to the synthetic work budget, and unavailable as raw host functions. Coordinates and sizes
are `Int`; drawing outside the active clip is discarded.

## Display and drawing

The display is a persistent, double-buffered 240x144 array of palette indices. Drawing state resets
at the start of each frame. `Color` is always one of the 32 immutable master-palette indices.
Logical index 0 is transparent while blitting sprites and remains an ordinary drawable framebuffer
colour.

| PXCL call                                 | Behavior                                                                   |
| ----------------------------------------- | -------------------------------------------------------------------------- |
| `clear(color)`                            | Fill the full back buffer, independent of camera and clip.                 |
| `pixel(x, y, color)`                      | Write one indexed pixel.                                                   |
| `line(x0, y0, x1, y1, color)`             | Draw an inclusive Bresenham line.                                          |
| `rect(x, y, width, height, color)`        | Draw a rectangle outline. Non-positive sizes draw nothing.                 |
| `rect_fill(x, y, width, height, color)`   | Draw a filled rectangle.                                                   |
| `circle(x, y, radius, color)`             | Draw an integer midpoint-circle outline.                                   |
| `circle_fill(x, y, radius, color)`        | Draw a filled midpoint circle.                                             |
| `triangle(x0, y0, x1, y1, x2, y2, color)` | Draw a filled integer triangle.                                            |
| `print(text, x, y, color)`                | Draw text using the original built-in 5x7 revision-1 bitmap font.          |
| `camera(x, y)`                            | Subtract an integer world-space camera origin from later draws.            |
| `clip(x, y, width, height)`               | Restrict later writes to a screen-space rectangle.                         |
| `clip_reset()`                            | Restore the full-screen clip.                                              |
| `pal(from, to)`                           | Remap a logical colour for later draws, or display scanout in `on raster`. |
| `pal_reset()`                             | Restore the identity drawing remap.                                        |
| `dither(x, y, first, second, level)`      | Select a colour from a fixed 4x4 Bayer pattern; level is clamped to 0-16.  |

`sprite(asset, x, y)` draws a named 1-64-pixel indexed sprite. `animation(asset, frame, x, y)`
selects a wrapped animation frame. `sprite_xform(asset, x, y, scale, quarter_turns, flip_x, flip_y)`
uses deterministic nearest-neighbour integer scaling from 1x through 16x and rotation in exact
quarter turns. Transformed output is charged more heavily than an ordinary blit.

`map(asset, x, y)` draws every layer of a named tile map in order using 8x8 tiles. A cartridge can
read bounded map data with `map_cell(asset, layer, x, y)`, which returns `-1` outside the map, and
`map_flag(asset, layer, x, y, flag)`, which returns `false` outside the map or for a flag outside
0-7. Sprite pixels, animation frames, tiles, map cells, fonts, and raster data share 128 KiB.

## Raster display list

`on raster(line: Int)` runs once for each scanline from 0 through 143 after `on draw`. Only
`pal(from, to)` and `raster_scroll(x, y)` are legal there. Their state is captured for that line and
remains in effect until changed by a later scanline. Scroll wraps the already drawn indexed back
buffer; palette changes happen during display resolution and do not alter framebuffer indices.

## Input and deterministic utilities

Four controller values are available as `pad1` through `pad4`. Button values are `up`, `down`,
`left`, `right`, `a`, `b`, `x`, `y`, `l`, `r`, `start_button`, and `menu`.

- `btn(controller, button)` reports the current frame state.
- `btnp(controller, button)` reports a false-to-true transition.
- `rng_num()` returns a deterministic value in `[0, 1)`.
- `rng_int(minimum, maximum)` returns an unbiased deterministic integer in the half-open range.

The host input adapter combines keyboard, pointer/touch, and standard gamepads. Pointer coordinates
are clamped to the virtual display and recorded alongside all four controller ports.

## Audio

`sfx(sound)` starts a named synthesizer patch. `music(music)` starts its eight-channel tracker order
list, and `music_stop()` stops tracker sequencing. The public asset representation can express pulse,
triangle, saw, noise, and 4-32-entry wavetable oscillators; frame-based attack/decay/sustain/release,
pitch slide, triangle vibrato, volume, and pan. It cannot represent imported PCM samples. Voice
allocation is deterministic and steals the oldest voice when all eight are active.

## Persistence status

`save_get_int(key, fallback)` reads a safe integer from the cartridge's initial save copy, and
`save_set_int(key, value)` updates worker-local state. Keys are 1-64 canonical ASCII characters.
Writes are returned to the trusted host in sorted frame batches and the Studio repository can flush
them to an isolated 8 KiB block keyed by immutable cartridge ID. Snapshot/restore includes save
state. A custom host must persist returned writes itself; worker-local writes are not durable merely
because a frame completed.
