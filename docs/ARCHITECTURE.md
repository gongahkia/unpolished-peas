# Architecture

`internal/sim` is the deterministic authority. `NewLabWorld(seed)` creates a versioned `LabLayout`, copies mutable terrain/object state into `World`, and advances it only from `InputFrame`.

`Player` contains one universal collision body and traversal state: buffered/coyote/double jump, wall/climb/mantle, roll/crouch/drop, dive, carried-object state, limited rope/bomb counts, and tether state. No transformation or combat state exists in the active simulation.

`WorldObject` represents physical crates/rocks, linked plates/doors/switches, vines/ropes, teleporters, bombs, and the exit. `StateHash` includes every future-affecting player, terrain, and object value. `RenderSnapshot` copies state for Ebitengine; visual animation cannot mutate physics or generator state.
