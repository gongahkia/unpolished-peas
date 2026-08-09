# Replay

A replay stores the simulation version, seed, ordered `InputFrame` values, and
a state hash per tick. `World.StateHash` excludes renderer state and detects
divergence at the earliest possible simulation tick. The world/encounter must
be recreated from the same seed and authored setup before calling `Play`; this
keeps replay input compact and the encounter setup independently testable.

`cmd/replaydump` inspects a JSON replay file. `SaveReplay` and `LoadReplay`
enforce explicit version and frame/hash consistency checks.
