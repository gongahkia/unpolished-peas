# Procedural movement labs

`GenerateMovementLab(seed)` uses a local RNG that is separate from simulation state. The generator creates a fixed movement syllabus rather than unconstrained noise: every lab contains all eight trial modules and a safe start/exit, while variants move ledges, nodes, teleport endpoints, and local obstacles.

Validation rejects malformed bounds, absent module types, invalid object dimensions, unresolved door links, and an invalid start/exit. Regression tests generate and validate 1,024 seeds, then compare same-seed fingerprints.

This deliberately favors comprehensible test variation over a content-expanding campaign generator. The important question is whether a physics change makes every generated relationship more or less interesting.
