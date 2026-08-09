# Replay

`72.replay.json` stores a movement-lab seed, every `InputFrame`, and a state hash after every tick. Replay version `72-lab-2` reconstructs `NewLabWorld(seed)` and stops at the first mismatched hash. Earlier replay files are deliberately rejected because the input contract and traversal state changed.

The hash includes generated geometry, mutable breakables, all object positions/links, player traversal state (including wall grace and ledge targets), carried-object state, and tether state. Rendering, camera position, and debug presentation are excluded.
