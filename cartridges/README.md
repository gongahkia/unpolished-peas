# Bundled cartridges

The three original PXCL/1 games are conformance and calibration projects. Every source and asset
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

Regenerate source-visible JSON assets and pack all Studio copies with:

```sh
pnpm --filter @px240c/studio generate:cartridges
```

Generated `.pxc` and standalone `.html` artifacts stay out of Git. A direct local export is:

```sh
cargo run -p px240c-cli -- export html cartridges/cinder-circuit
```
