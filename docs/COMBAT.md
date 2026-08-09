# Movement rules

Combat is disabled for this test slice. The file remains the canonical input-to-motion contract until combat returns.

- Ground movement accelerates and decelerates; facing is independent of aim.
- Jump supports variable height, a seven-tick coyote window, a seven-tick input buffer, and one air jump. Wall contact enables a controlled slide, wall jump, and climb.
- Roll is available on ground and in air, uses a lower collision body, and remains crouched under low ceilings. `S` plus jump drops through one-way platforms; holding `S` while falling enters a dive that breaks marked floors.
- `E` picks up/drops physical objects and activates nearby world objects. `J` throws a held object along aim. `Q` creates one of three timed bombs; `R` deploys one of three climbable ropes; `F` toggles the 142-pixel tether probe.

The HUD reports active traversal state, remaining air jump, coyote time, tools, held object, and aim. Debug mode shows object links and module names.
