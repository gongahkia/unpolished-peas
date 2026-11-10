# Ashen Causeway

Design established 2026-11-10, before implementation. Status: implemented and reviewed as a bounded developer build; see the
[November 11 assessment](ASSESSMENT-2026-11-11.md) for proof and limits.

The last ferryman carries a living coal through a drowned monastery to rekindle
its beacon. Ring three mooring bells, open the return lift, and defeat the Bell
Warden. The ending returns light to the flooded causeway and names the people
who kept it alive. Target: 15–30 minutes for a first successful run; unmeasured.

## Bounded content

Three connected areas: Reed Quay (movement and isolated duels), Silt Cloister
(two flanking corridors, ranged pressure, optional reliquary), and Beacon Crown
(vertical approach and a spacious boss court). Each has a rest lantern. A lift
unlocked from the Cloister connects back to the Quay and bypasses its encounters.
Optional reliquaries grant a flask charge and a stamina charm. Four enemies:
Drifter (slow cleave), Pike Watch (long thrust), Censer (stationary ranged shots),
and Hound (short approach dash, long recovery). Do not pack overlapping attacks
around respawn points. Boss: Bell Warden, measured hammer arcs in phase one;
below half health, a clearly announced transition adds alternating shock rings
with a safe retreat interval. No damage during transition.

Two freely switchable weapons: ferryman's sabre and mooring spear. Ember currency
buys three capped weapon upgrades or vitality upgrades at lanterns. One equipped
charm trades mobility/stamina benefits; no inventory grid, loot randomization,
parry, block, lock-on, crafting or procedural levels. These are explicit scope
choices; every feature requested in the objective remains in scope.

## Controls and combat contract

Keyboard/mouse must complete every route: WASD/arrows move, mouse aims, left click
or J light, right click or K heavy, Space dodge, H heal, E interact, Q switch
weapon, Escape pause. Gamepad uses stick movement/aim with facing retained while
neutral; South dodge, shoulder attacks, North heal, West interact, Start pause.
Menus describe bindings. Input rebinding uses public ActionMap facilities.

60 fixed ticks/second. Facing is captured at attack start; attacks cannot turn,
move or cancel until recovery ends. Dodge captures movement direction, or facing
when stationary. No roll cancel from attacks/heals. A single pending action
expires after 8 ticks; latest action replaces earlier input. Rejected actions
provide a cue. A valid buffered input starts on the first free tick.

| Weapon/action | Startup | Active | Recovery | Stamina | Damage | Reach |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Sabre light | 7 | 4 | 13 | 18 | 22 | 28 |
| Sabre heavy | 19 | 5 | 23 | 34 | 44 | 34 |
| Spear light | 12 | 3 | 18 | 22 | 27 | 44 |
| Spear heavy | 27 | 4 | 28 | 42 | 58 | 52 |

Intervals are half-open, measured from age zero. Dodge costs 28, lasts 26 ticks,
and grants invulnerability at ages [3,15). Healing consumes a flask on acceptance,
restores 45 HP at age 36, and commits for 60 ticks. Stamina regenerates one per
tick after a 36-tick delay while idle; exhaustion uses the same delay and cannot
spend below zero. Hits interrupt vulnerable actions, impose 12 ticks stagger,
and grant 36 ticks damage immunity to prevent stun locks. One attack can damage
each target once. Solid walls block attack line segments and movement; enemies
obey the same collision boundary. Knockback resolves against walls.

Death replaces any older currency drop with currently carried currency, even if
zero. Respawn restores HP, stamina and flasks at the last lantern, resets normal
enemies and transient combat/projectiles, preserves permanent unlocks and boss
victory. Recovering the drop returns its currency once. Resting follows the same
enemy/resource reset. No save serializes an attack or a projectile.

## Presentation and ownership

Ordinary Canvas, 480×270 logical pixels. Ink blue water, pale sandstone, warm
copper lanterns, deliberate low resolution silhouettes and short directional
weapon trails. Enemy anticipation uses pose, shape and sound as well as color.
HUD: named health/stamina bars, flask count, embers, weapon and current objective.
Calm sparse bell/drone ambience persists across the journey; separate music/effects
volume and event bell cues distinguish combat. Flash and shake toggles default restrained. Original procedural art/audio
retain generation sources and provenance; reused fonts retain notices.

Title (Continue/New game/settings/credits), contextual tutorial, pause, settings,
death with recovery explanation, victory and credits are required screens.
Prepare authored text outside drawing. Fixed capacities: 32 enemy slots, 32 shots,
four rings, one currency drop and static room geometry (at most four wall rectangles in the current areas).
Hit/hurt effects use fixed counters; there is no standalone visual-effect pool.
No recurring world-rule/drawing allocations; profile portable service requests separately.
PROFILE.md records small update-time storage/audio requests and zero draw/mix
allocation events along the complete route. Hosts own capabilities; game releases
all loaded assets/layouts/audio handles at shutdown, including partial-init cleanup.

Save version 1 explicitly encodes checkpoint, currency, drop, weapon, upgrades,
charms, permanent unlocks, boss victory and settings. Continue restores rested
state. Missing/corrupt data starts safely with a visible explanation; failed writes
show a persistent warning and preserve the previous good blob. New game must
explicitly replace progress. Verify real process and browser reloads.

## Acceptance and evidence gates

Completion requires all objective requirements, not merely the initial combat
module. Deterministic boundary tests cover combat, collision, AI, progression,
death/recovery, saves and lifecycle. A full normal-input route must demonstrate
opening → three areas → shortcut/reward → two boss phases → ending, plus death,
drop loss/recovery, both weapons, upgrades, save/continue and repeated restarts.
Review actual native/browser captures and interactions; iterate visible defects.
Build through an external consumer. Run native, Chromium, Firefox and available
Safari portable workflows. Report hardware checks separately. Profile ordinary
and busiest combat with existing tools and record hardware, build, workload,
frame times and allocations. First-run duration remains a target until measured.
Canonical FRICTION.md records evidence, including facilities that work well.
A dated assessment and GUIDE.md must link commands, evidence, limitations and
focused commit IDs. Every existing README stays unchanged. No publish or push.

## Implemented enemy rules — 2026-11-10

All values are fixed 60 Hz ticks. Normal enemies acquire a visible player inside
240 pixels, commit aim at anticipation start and do not track during the strike.

| Enemy | Anticipation | Output | Recovery |
| --- | ---: | --- | ---: |
| Drifter | 42 | 32-pixel cleave fan, dot(direction)>0.45, 18 damage | 48 |
| Pike Watch | 48 | 56-pixel forward thrust, 10-pixel half-width, 18 damage | 48 |
| Censer | 70 | One locked-direction shot: speed 2.5 pixels/tick, radius 3, life 180 ticks, 18 damage | 48 |
| Hound | 34 | Nine 3-pixel approach steps, then 30-pixel bite corridor with 14-pixel half-width, 18 damage | 72 |
| Warden phase one | 54 | 76-pixel cleave fan, 32 damage | 64 |
| Warden phase two melee | 36 | Same cleave, alternating with bell shock | 64 |
| Warden phase two shock | 72 | Expanding circular band from radius 20 to 200 over 60 ticks, 26 damage | 84 |

Melee damage is checked once per attack during active ages 1–10. The active-age-0
pose is the release cue before that first damage check. Censer emits its shot at
release and has no instant beam damage. Shock collision uses the swept band plus
13 pixels for band/player extent; its inner space is safe. A dodge or existing
immunity consumes a crossing so the trailing edge cannot damage the player after
a successful dodge. Walls occlude melee, shots and shocks. After half health, the
Warden has a 120-tick invulnerable, non-attacking transition and a full recovery
before alternating attacks begin. Shocks clear when the Warden dies.

Damaging an enemy causes knockback and at most one 18-tick stagger per 180 ticks.
The original 72-tick resistance allowed light attacks to keep postponing windup;
a stress regression reproduces that failure and proves the longer guard permits
an attack. This is game combat policy, not a framework facility. Hazard capacities
are 32 shots and four rings; an exhausted pool skips a new spawn rather than
replacing a live hazard. Rest, respawn and room transition clear both arrays.


## Final acceptance review — 2026-11-11

| Requirement | Reviewed evidence |
| --- | --- |
| Beginning, three connected areas, ending and all screens | Full input routes, actual host winning/reload checks, menu and death captures |
| Deliberate combat, four archetypes and two boss phases | Timing/fairness regressions, actual boss routes, archetype pose studies and slowed combat excerpts |
| Two weapons, equipment, upgrades, lanterns, useful lift/reward | Full keyboard/virtual-controller routes; menu feedback and save tests |
| Death/drop loss/recovery/reset | Rule regressions plus actual normal-input death/respawn/recovery captures |
| Cohesive presentation and feedback | Authored text/landmarks/silhouettes, original score/effects, pose and rejection-feedback corrections, actual UI captures |
| Public workflow, persistence and cleanup | Fresh archive consumer; SDL and three-browser reloads; explicit shutdown/resource assertions |
| Representative performance/resources | Ordinary and shock CPU/SDL profiles, allocation observations and retained tail data in PROFILE |
| First-success duration/enjoyment | Unverified; 15–30 minutes remains a design target, with a substantial pacing risk from the fast expert route |

The original proposed 64-effect pool and 16-wall budget were unnecessary: current
feedback uses counters and bounded hazards, and actual geometry is static. This
records the implemented capacity rather than implying unused pools exist. No
required player-facing system was dropped. The external first-play/hardware checks
remain explicit limits; automated routes do not establish subjective enjoyment.


Geometry detail: player melee requires center distance at most nominal reach plus
nine pixels of target extent, forward dot product greater than 0.55 and clear wall
visibility. Enemy melee includes targets within eight pixels of its center from
any facing; farther targets use the fan/thrust rules above. These are the actual
center/extent tests, rather than a claim that every painted weapon pixel damages.
