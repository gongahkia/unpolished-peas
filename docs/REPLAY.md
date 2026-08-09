# Replay

A run replay stores the simulation version, seed, ordered input frames, route
choices, vows, retries, and a state hash per frame. `RunReplay.Play` recreates
the entire pilgrimage from these values; `World.StateHash` excludes renderer
state and detects divergence at the earliest possible tick.

`cmd/replaydump` verifies and inspects a JSON run replay. `SaveRunReplay` and
`LoadRunReplay` enforce explicit version and frame/hash consistency checks.
