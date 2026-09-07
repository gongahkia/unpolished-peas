# Bundled cartridges

These three original PXCL/1 cartridges are conformance and calibration projects. Every source and
asset file is inspectable, all three build through the public `px240c` command, and each is credited
to `@gongahkia`.

- `cinder-circuit`: camera-scrolling tile platformer. Arrow keys move, Z jumps, and Z/Enter starts.
- `ashvault`: deterministic turn-based fog-of-war roguelike. Arrow keys move and Z/Enter starts.
- `raster-rush`: scanline pseudo-3D racer. Arrows steer, Z accelerates, X brakes, and A boosts. At
  the title, Z selects solo, A two players, S three players, and Enter four players. Standard
  gamepads map to the four controller ports; the second keyboard port uses I/J/K/L and F/G/R/T.

Regenerate source-visible JSON assets and pack all Studio copies with:

```sh
pnpm --filter @px240c/studio generate:cartridges
```

Generated `.pxc` and standalone `.html` artifacts stay out of Git. A direct local export is:

```sh
cargo run -p px240c-cli -- export html cartridges/cinder-circuit
```
