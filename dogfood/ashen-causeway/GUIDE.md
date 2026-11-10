# Ashen Causeway development build

This is an unfinished action RPG prototype. The complete scope and acceptance
gates remain in [DESIGN.md](DESIGN.md). Authored audiovisual presentation,
projectiles, distinct boss phase mechanics, complete-route verification and final
encounter tuning are still pending.

From this directory, using Zig 0.15.2:

```
zig build test
zig build run
zig build web
python3 -m http.server --bind 127.0.0.1 --directory zig-out/web 8000
```

Open http://127.0.0.1:8000/ for the browser build. Native uses SDL3; the public
package dependency currently points to the engine checkout two directories up.
External archive-consumer verification remains pending.

Arrows or left stick choose menu options; Enter, E or South accepts. Continue
restores a saved journey; New Game explicitly replaces progression while retaining
settings. Escape/Start opens pause and backs out of settings. WASD/arrows move and set facing. Moving the mouse sets aim;
J/left click attacks, K/right click performs a heavy attack, Space dodges,
H heals, Q switches sabre/spear, E interacts, Escape pauses. Select Resume or
press Escape/Start to resume. After death, Enter/E respawns. Controller bindings: left stick moves,
right stick aims, shoulders attack, South dodges, North heals, West interacts,
Back switches weapons and Start pauses/resumes. Physical controller validation
has not been performed.

Each area is 960×540 world pixels, viewed through a 480×270 camera. The lantern
at (70,270) restores health/stamina/flasks, resets enemies and sets the checkpoint.
The bell at (870,450) opens that area's east passage; E near x>900 travels east.
E near x<50 travels back west. Ringing the Cloister bell unlocks a lift at
(110,450) in both first areas. A Cloister reliquary at (480,100) grants 75 embers, a
fourth flask and the reed charm.
Enemies currently use letter labels D/P/C/H/W; final silhouettes and telegraphs
remain pending. Censer currently uses a long directional attack rather than the
planned projectile. Boss phase two currently changes timing; planned shock rings
remain pending. Once the Warden is defeated, ring the third bell and interact
with it again to rekindle the beacon, then view victory and credits. This build does not meet completion gates.

Death drops carried embers, replacing any earlier drop even if carrying zero.
Walk over the drop to recover it once. Respawn resets enemies and combat resources
but preserves bells, lift, reliquary and boss defeat.

At a lantern, pause and choose weapon or vitality upgrades. Each has three levels,
costing 50, 100 and 150 embers. Weapon levels add six damage each. Vitality adds
15 maximum HP per level; rest to fill the new capacity. Equip/remove the reed
charm at a lantern: it adds 25 maximum stamina and reduces walking speed from
102 to 90 world pixels/second. Normal regen and healing respect equipped capacity.

Saves use the portable SaveStore key `journey-v1`, explicit format `ASH1` version
1, forty bytes with a corruption checksum. They persist checkpoint, currency and
drop location/amount, weapon, upgrades, bells, shortcut, reliquary/charm, boss
victory, ending and settings. Autosaves occur when these values change. Pause
provides Save/Retry. Continue starts at the last lantern with restored resources
and reset normal enemies; transient position, HP, attacks, timers and enemy combat
state are excluded. Missing saves allow Begin. Invalid/unreadable saves show an
explanation and remain untouched until New Game is selected. A failed write keeps
the last good blob and a visible warning; retry after storage becomes available.

Settings persist separate music/effects volume values and restrained-effects
preferences within the same blob. Audio, shake and flash presentation are not yet
implemented, so those controls currently store preferences for the pending work.
Browser reload, rejected-write preservation and retry have been exercised in
Chromium/Firefox. Actual native process-reload verification is still pending.

See [PROGRESS.md](PROGRESS.md) for checks actually run and [FRICTION.md](FRICTION.md)
for framework observations. Test passage alone does not establish game polish,
play duration, enjoyment, renderer parity or hardware compatibility.
