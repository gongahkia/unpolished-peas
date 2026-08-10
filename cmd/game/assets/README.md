# Texture atlases

## Player atlas

`player-atlas.png` is a 256×256 transparent texture atlas made from a Codex-generated pixel-art sprite sheet. It contains sixteen 64×64 cells in row-major order:

1. idle, alert idle, run contact, run airborne
2. jump takeoff, rising jump, fall, double jump
3. roll, crouch, wall cling, wall jump
4. ledge hang, mantle, dive, and reserved future variants

The renderer maps those cells to the deterministic traversal snapshot and adds only renderer-local bob, squash/stretch, tilt, shadows, and motion accents. The art must not affect the simulation or replay hash.

The player atlas remains embedded and validated, but the playtest renderer intentionally does not draw it.

## Enemy atlas

`enemy-atlas.png` is a 256×256 transparent texture atlas with sixteen 64×64 cells in row-major order:

1. charger: idle, roam, telegraph, charge
2. hopper: idle, windup, airborne, landing
3. diver: idle, telegraph, dive, stunned
4. reserved future variants

The renderer maps deterministic enemy state, movement, and timer data to those cells. Like the player atlas, this animation is presentation-only and cannot modify the simulation or replay hash.
