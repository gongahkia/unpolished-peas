# Architecture

The game advances in 60 deterministic simulation ticks per second. The
Ebitengine adapter samples physical input into `sim.InputFrame`; it never
mutates combat state directly. `sim.World.Step` owns player actions, collision,
damage, AI, boss patterns, run state, and seeded random decisions. It returns a
`RenderSnapshot` that is consumed by the glyph renderer.

Simulation packages must not import Ebitengine. Rendering randomness is kept
outside the simulation, and all gameplay randomness comes from `World.RNG`.
That makes an ordered input stream replayable and allows headless tests.

This prototype intentionally uses an explicit world/entity model rather than
an ECS: `World` owns a `Player`, enemies, projectiles, clones, and effects.
