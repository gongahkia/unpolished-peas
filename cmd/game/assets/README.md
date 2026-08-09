# Player atlas

`player-atlas.png` is a 256×256 transparent texture atlas made from a Codex-generated pixel-art sprite sheet. It contains sixteen 64×64 cells in row-major order:

1. idle, alert idle, run contact, run airborne
2. jump takeoff, rising jump, fall, double jump
3. roll, crouch, wall cling, wall jump
4. vine climb, ledge hang, mantle, dive

The renderer maps those cells to the deterministic traversal snapshot and adds only renderer-local bob, squash/stretch, tilt, shadows, and motion accents. The art must not affect the simulation or replay hash.
