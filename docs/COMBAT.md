# Movement rules

Combat is disabled for this test slice. The file remains the canonical input-to-motion contract until combat returns.

- Ground movement accelerates and decelerates; facing is independent of aim.
- Jump supports variable height, a seven-tick coyote window, a seven-tick input buffer, and one air jump. Holding toward a wall creates a controlled slide; the contact direction persists for five ticks so a late wall-jump remains responsive.
- A ledge creates a twelve-tick grab state. Jump or holding toward the ledge climbs; down drops. Roll is available on ground and in air, uses a lower collision body, and remains crouched under low ceilings. `S` plus jump drops through one-way platforms or, in the air, begins a committed dive that breaks marked floors.
- `E` picks up/drops physical objects and activates nearby world objects. `J` throws a held object along aim. `F` toggles the 142-pixel tether probe.

The HUD reports active traversal state, remaining air jump, coyote time, wall-jump grace, held object, and aim. Debug mode shows object links and module names.
