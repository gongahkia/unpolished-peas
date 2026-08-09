# Architecture

`internal/sim` is the deterministic authority. `NewRunWorld(seed)` creates a versioned `RunLayout`, copies mutable terrain/object state into `World`, instantiates deterministic enemy spawns, and advances it only from `InputFrame`.

`Player` contains one universal collision body and traversal state: buffered/coyote/double jump, wall-slide/jump grace, ledge grab/mantle, roll/crouch/drop, downward smash, and carried-object state. Environmental combat is deliberately small: stomp, throw, bait, collision, hazard, and breakable-terrain interactions; no weapon or RPG system exists.

`WorldObject` represents physical crates/rocks, linked plates/doors, treasure, and the exit. `Enemy` has three deterministic state machines: charger, hopper, and diver. `StateHash` includes every future-affecting player, terrain, object, enemy, statistic, and hitstop value. `RenderSnapshot` copies state for Ebitengine; visual animation and impact bursts cannot mutate physics or generator state.
