# Bundled cartridges

The three original PXCL/1 games remain the primary play cartridges. Every source and asset
file is inspectable, all cartridges build through the public `px240c` command, and each is credited
to `@gongahkia`.

- `cinder-circuit`: camera-scrolling tile platformer across four 2,048-pixel relay circuits. Arrow
  keys move, Z jumps, and Z/Enter starts; its 30 Hz update rate makes a clean uninterrupted run about
  4 1/2 minutes before platforming mistakes or life resets.
- `ashvault`: deterministic turn-based fog-of-war roguelike. Arrow keys move and Z/Enter starts.
- `raster-rush`: scanline pseudo-3D racer. Arrows steer, Z accelerates, X brakes, and A boosts. At
  the title, Z selects solo, A two players, S three players, and Enter four players. Standard
  gamepads map to the four controller ports; the second keyboard port uses I/J/K/L and F/G/R/T.
- `px240c-service`: source-visible Hardware Revision 1 service cartridge. It runs live checks over
  the public bus/API and presents eight diagnostic pages; A/right and B/left change pages.
- `signal-4k`: complete 2,364-byte procedural audiovisual transmission. It drives work RAM, raster
  palette/scroll and production synth; A retransmits its signal.
- `pocket-relay`: complete 4,609-byte one-minute catching game with custom bitmap digits, synth
  feedback, deterministic RNG and isolated best-score save.
- `hardware-gauntlet`: complete 4,619-byte public-API stress display for bus/ROM, endian access,
  framebuffers, raster, four ports, wavetable audio, custom font, task scheduling and work counters.

The first three entries are the preserved games; the final three are truthful size-class dogfood.
Their class is determined from the complete canonical source-visible `.pxc`, never just source or
compressed code.

Regenerate source-visible JSON assets and pack all Studio copies with:

```sh
pnpm --filter @px240c/studio generate:cartridges
```

Generated `.pxc` and standalone `.html` artifacts stay out of Git. A direct local export is:

```sh
cargo run -p px240c-cli -- export html cartridges/cinder-circuit
```
