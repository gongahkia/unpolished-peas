# Runnable PXCL examples

Every path below is an ordinary project accepted by `px240c check`, `run`, `test`, `pack`, and
Studio import. They use only public PXCL/1 and Hardware Revision 1 interfaces.

| Topic                                                                                                        | Small runnable source          |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------ |
| pixel, primitives, input, animation, sound, save, packing                                                    | `cartridges/pxcl-tutorial`     |
| sprites, maps, raster, custom fonts, synth/tracker, four ports, tasks, saves, modules, tests, bus, profiling | `examples/api-tour`            |
| focused RAM/ROM/endian/raster/audio/task/port stress                                                         | `cartridges/hardware-gauntlet` |
| procedural graphics/audio size coding                                                                        | `cartridges/signal-4k`         |
| a complete small game loop                                                                                   | `examples/relay-catch`         |

Start with `px240c run examples/api-tour`, then inspect both source modules and
`tests/smoke.pxl`. `px240c test examples/api-tour` runs its pure assertion and deterministic
scripted-frame example. The `templates/` directory contains deliberately small blank, arcade,
platform, grid/roguelike, and four-player starting points; they are examples, not a hidden engine.
