# Player atlas

`player-atlas.png` is a 256×256 transparent texture atlas made from a Codex-generated pixel-art sprite sheet. It contains sixteen 64×64 cells in row-major order:

1. idle, alert idle, run contact, run airborne
2. jump takeoff, rising jump, fall, double jump
3. roll, crouch, wall cling, wall jump
4. ledge hang, mantle, dive, and reserved future variants

The cells are reserved for a future renderer mapping from the deterministic
traversal snapshot. That mapping must keep bob, squash/stretch, tilt, shadows,
and motion accents presentation-only; the art must not affect the simulation or
replay hash.

The player atlas remains source art in the repository, but the playtest renderer
intentionally does not load or draw it.

## Test enemy atlas

`test-enemy-atlas.png` is a standalone 256×256 transparent trial sheet. Its first three rows contain charger, hopper, and diver poses; the final row is reserved. It is deliberately not wired into the renderer so the schematic enemy presentation remains the active playtest baseline.
