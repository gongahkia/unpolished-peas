# Replay

`72.replay.json` stores a movement-lab seed, every `InputFrame`, and a state hash after every tick. Replay version `72-lab-1` reconstructs `NewLabWorld(seed)` and stops at the first mismatched hash.

The hash includes generated geometry, mutable breakables, all object positions/links/fuses, player traversal state, tools, and tether state. Rendering, camera position, and debug presentation are excluded.
