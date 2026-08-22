# Procedural runs

`GenerateRun(seed)` uses a local RNG that is separate from simulation state. It shuffles ten authored room templates, chooses controlled encounter archetypes (including all three in every run), then places objects and optional treasure. It does not synthesize arbitrary tiles or precision challenges.

Validation rejects malformed room bounds, absent templates, unsafe object/enemy positions, unresolved door-to-plate links, missing floor routes, inadequate treasure coverage, and an invalid final exit. Regression tests generate and validate 1,024 seeds, compare same-seed fingerprints, and check entry/exit safety across 128 seeds.

This deliberately favors readable variation over content volume. The generator guarantees a basic route; the player-authored decision is whether to take the higher, riskier opportunity around it.
