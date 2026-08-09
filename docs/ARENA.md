# Validation arena

`72` has one authored, bounded combat world. Its simulation bounds are
1280×720; the camera shows a 640×360 follow viewport. There are no adjacent
maps, procedural rooms, or open-world systems.

The player starts at `(150, 500)` and Warden starts at `(1050, 250)`, outside
the opening viewport. The minimap is the authoritative overview: terrain is
shown in colour, green marks the player, red marks Warden, and the white frame
shows the current viewport.

## Terrain layout

- The central water region spans `(300, 210)` to `(700, 390)`. Monkey, Tiger,
  and Mantis must route around it; Bird can cross it directly and ignores
  hazard damage.
- The north and south edges around the water provide ordinary ground routes.
  The starting position is south of the water and Warden is north-east of it.
- The cracked wall at the water’s east lip spans `(700, 305)` to `(734, 417)`.
  Tiger pounces can break it, opening a more direct central-east line.
- Pillars at `(490, 84)`, `(900, 212)`, and `(875, 492)` block projectile and
  staff lines. They give cover while approaching or fighting Warden.
- Solid walls at `(118, 575)` and `(770, 142)` shape the outer routes and make
  knockback positioning consequential.

Long staff attacks cross water but stop on pillars, walls, and intact cracked
walls. Warden’s projectile fans and sweep make route choice matter before the
player reaches melee range.
