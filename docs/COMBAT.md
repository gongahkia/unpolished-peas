# Combat

The arena is designed for movement and aim to be separate. Move with `WASD` while arrows continuously set the attack line. Short, medium, and long are different commitments, not a shared attack with altered range.

| tool | timing | use |
| --- | --- | --- |
| short | 2 startup, 3 active, 4 recovery; 34 range | close reactive pressure and a precise melee deflect window |
| medium | 5 startup, 5 active, 10 recovery; three escalating sweeps | general combo pressure, multi-target coverage, and clearing clustered projectile fans |
| long | hold up to 48 ticks; 28–136 range; 24 recovery on release | directional control, long guard breaks, knockback, and attacks across water |

While charging long, movement is reduced to 32%. Missing is deliberately much more expensive than with the other two modes.

The renderer keeps the ready or recovering staff compactly carried beside Monkey, never projecting it as attack reach. Orange dashed lines forecast windup reach, bright yellow full-length lines denote damaging frames, and an orange long line denotes a non-damaging charge. The bottom readout names `READY`, `WINDUP`, `ACTIVE`, `RECOVERY`, or `CHARGING`; forms label the staff as replaced rather than implying an unavailable attack is active.

The authored arena contains water, two projectile-blocking pillars, a cracked wall, and a solid wall. Water blocks normal ground movement but Bird crosses it. Pillars stop staff lines and projectiles. Tiger pounces through the cracked wall; knockback into solid terrain damages and staggers enemies. Long attacks are straight-line tools that can operate over water but stop on solid cover.

Feedback has central tiers: ordinary hits apply two ticks of hitstop, a small impact and restrained trauma; heavy hits apply five ticks, stronger knockback and a larger burst; counters and phase transitions add slow motion and major trauma. Effects feed one trauma value rather than writing camera offsets directly.
