# Replay

A replay stores the simulation version, seed, and ordered `InputFrame` values.
`World.StateHash` excludes renderer state and is used by regression tests and
the replay dumper to detect divergence.
