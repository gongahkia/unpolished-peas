# Replay

`wukong.replay.json` stores a run seed, every `InputFrame`, and a state hash after every tick. Replay version `72-run-3` reconstructs `NewRunWorld(seed)` and stops at the first mismatched hash. Earlier movement-lab and run replay files are deliberately rejected because the generator and simulation contract changed.

The hash includes generated geometry, mutable breakables, object positions/links, all enemy state, player traversal state (including wall grace and ledge targets), run statistics, carried-object state, and hitstop. Rendering, camera position, impact-burst presentation, and debug presentation are excluded.
