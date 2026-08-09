# Validation stage

`72` has one authored, bounded side-view stage. Simulation bounds are 1280×720 and the camera is a 640×360 follow viewport. There are no adjacent maps, procedural rooms, or open-world systems.

The player starts on the west shelf at `(150, 500)`. Warden starts on the raised east platform at `(1060, 319)`, outside the opening viewport. The minimap shows terrain in colour, the player in green, Warden in red, and the active camera frame in white.

## Terrain layout

- Solid ground occupies `x=0–280` and `x=720–1280` from `y=650` down. Water fills the floor gap at `x=280–720`; it damages normal forms but Bird ignores it.
- One-way landing platforms sit at `(70, 530)`, `(330, 500)`, `(545, 420)`, `(760, 510)`, and `(945, 340)`. They catch falling bodies but can be jumped through from below.
- The cracked wall at `(700, 500)` is two hits of Tiger pounce away from opening the direct east route.
- The pillar at `(875, 390)` and the east wall at `(1200, 430)` are full solids. They block staff/projectile lines and make knockback placement matter; one-way landing platforms do not block combat lines.

Long staff can strike over the water gap but stops at a pillar, wall, or intact cracked wall. Bird’s small, gliding route avoids the hazard. Tiger converts the wall into a route. The ordinary route is a sequence of jumps and landings, so the stage tests platform control before and during Warden pressure.
