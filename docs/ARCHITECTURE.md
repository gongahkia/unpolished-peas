# Architecture

`internal/sim` is the single deterministic authority. It advances at 60 Hz from `InputFrame`; each frame contains independent `MoveX/MoveY` and `AimX/AimY` vectors. The simulation never derives aim from movement.

`World` owns the 1280×720 validation arena, Warden, terrain, player, Echo frames, projectiles, effects, hitstop, slow motion, and camera trauma. The renderer presents a 640×360 follow viewport over that bounded world and keeps the HUD/minimap in screen space. `RenderSnapshot` copies only renderer-facing state. The Ebitengine layer reads controls and draws ASCII glyphs and primitives; it cannot modify the simulation.

Simulation randomness uses `World.RNG`. Renderer motion is derived from the snapshot tick, so screen shake and effect variation cannot perturb replays. `Replay` records every input and a state hash after each step; playback checks every recorded hash against a fresh validation world with the same seed.
