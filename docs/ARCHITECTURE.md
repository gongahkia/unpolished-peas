# Architecture

`internal/sim` is the deterministic authority. It advances at 60 Hz from `InputFrame`: `MoveX` is horizontal run intent, `Jump` is a separate edge-triggered platform action, and `AimX/AimY` is independent staff direction. No combat code derives aim from movement.

`World` owns the 1280×720 stage, gravity, one-way platform/full-solid collision, water hazards, Warden, player, Echo frames, projectiles, effects, hitstop, slow motion, and camera trauma. The renderer presents a 640×360 follow viewport and screen-space HUD/minimap. `RenderSnapshot` copies renderer-facing state only; the Ebitengine layer cannot mutate simulation state.

Simulation randomness uses `World.RNG`. Renderer motion is derived from the snapshot tick, so shake and effect variation cannot perturb replays. `Replay` records every input and state hash; playback checks every recorded hash against a fresh validation stage with the same seed.
