# Combat

`72` is a side-view platform brawler. Horizontal movement and staff aim are separate deterministic inputs: `A`/`D` run, `W`/`Space` jump, and arrow keys continuously set a two-dimensional attack direction. The simulation never derives aim from running direction.

| tool | timing | platform-brawler use |
| --- | --- | --- |
| Short | 2 startup, 3 active, 4 recovery; 34 range | reactive point-blank strike and precise melee deflection |
| Medium | 5 startup, 5 active, 10 recovery; three escalating sweeps | grounded or aerial general-purpose chain; clears clustered projectile fans |
| Long | hold up to 48 ticks; 28–136 range; 24 recovery on release | directional lane control across water/platform gaps, guard breaking, and heavy knockback |

Long reduces horizontal running to 32% while charging. Its orange extension and endpoint show current length; it is non-damaging until release. Solid cover blocks all staff lines; water does not.

The cyan chevron and HUD `AIM` label always show direction without implying an attack. Monkey carries a short diagonal staff when ready or recovering. Orange dashed reach is windup only; bright yellow full-length staff is active damage; the bottom HUD spells out `READY`, `WINDUP`, `ACTIVE`, `RECOVERY`, or `CHARGING`. Transformations state that staff has been replaced rather than showing a false attack line.

Combat feedback is tiered and centralized: ordinary hits apply two ticks of hitstop, a small burst, knockback, and restrained camera trauma. Heavy hits use five ticks and a larger burst. Mantis counters, guard breaks, armor breaks, and phase transitions add slow motion and major trauma. Rendering derives shake from the snapshot, so visual randomness cannot affect replay state.
