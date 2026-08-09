# Movement and environmental combat

The player has no conventional attack string. Survival comes from movement and environmental interactions.

- Ground movement accelerates and decelerates; facing is independent of aim.
- Jump supports variable height, a seven-tick coyote window, a seven-tick input buffer, and one air jump. Holding toward a wall creates a controlled slide; the contact direction persists for five ticks so a late wall-jump remains responsive.
- A ledge creates a twelve-tick grab state. Jump or holding toward the ledge climbs; down drops. Roll is available on ground and in air, uses a lower collision body, and remains crouched under low ceilings. `S` plus jump drops through one-way platforms or, in the air, begins a committed dive that breaks marked floors.
- `E` picks up/drops physical objects. `J` throws a held object along aim. A falling player stomps an enemy and bounces upward; contact without a stomp is lethal.
- Chargers telegraph then commit horizontally, breaking fragile walls and kicking movable objects. Hoppers jump on a predictable rhythm. Divers hover, telegraph, then commit to a dive. All three can be stomped, hit by a fast rock, or killed by spikes.

Breakable terrain reacts to downward smashes, charging enemies, and sufficiently fast thrown objects. Small hitstop, impact bursts, flashes, and screen shake distinguish meaningful impacts from ordinary movement.
