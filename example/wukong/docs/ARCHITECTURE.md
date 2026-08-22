# Architecture

`internal/sim` is the deterministic authority. `NewRunWorld(seed)` creates a versioned `RunLayout`, copies mutable terrain/object state into `World`, instantiates deterministic enemy spawns, and advances it only from `InputFrame`. The example adapts that state to the public engine runtime through ordered world and screen-space render layers; neither the engine camera nor visual callbacks can modify replay state.

`Player` contains one universal collision body and traversal state: buffered/coyote/double jump, wall-slide/jump grace, ledge grab/mantle, roll/crouch/drop, downward smash, and carried-object state. Environmental combat is deliberately small: stomp, throw, bait, collision, hazard, and breakable-terrain interactions; no weapon or RPG system exists.

`WorldObject` represents physical crates/rocks, linked plates/doors, treasure, and the exit. `Enemy` has three deterministic state machines: charger, hopper, and diver. `StateHash` includes every future-affecting player, terrain, object, enemy, statistic, and hitstop value. `RenderSnapshot` copies state for the renderer; visual animation, impact bursts, and the seeded three-plane environment cannot mutate physics or generator state.
