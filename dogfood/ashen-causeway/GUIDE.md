# Ashen Causeway development build

This is an unfinished action RPG prototype. The complete scope and acceptance
gates remain in [DESIGN.md](DESIGN.md). Saves, finished authored presentation,
upgrades, a complete ending and final encounter tuning are still pending.

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

Enter or E starts. WASD/arrows move and set facing. Moving the mouse sets aim;
J/left click attacks, K/right click performs a heavy attack, Space dodges,
H heals, Q switches sabre/spear, E interacts, Escape pauses. Enter/E/Escape
resumes. After death, Enter/E respawns. Controller bindings: left stick moves,
right stick aims, shoulders attack, South dodges, North heals, West interacts,
Back switches weapons and Start pauses/resumes. Physical controller validation
has not been performed.

Each area is 960×540 world pixels, viewed through a 480×270 camera. The lantern
at (70,270) restores health/stamina/flasks, resets enemies and sets the checkpoint.
The bell at (870,450) opens that area's east passage; E near x>900 travels east.
E near x<50 travels back west. Ringing the Cloister bell unlocks a lift at
(110,450) in both first areas. A Cloister reliquary at (480,100) grants embers.
Enemies currently use letter labels D/P/C/H/W; final silhouettes and telegraphs
remain pending. Censer currently uses a long directional attack rather than the
planned projectile. Boss phase two currently changes timing; planned shock rings
and a victory interaction are pending. This build does not meet completion gates.

Death drops carried embers, replacing any earlier drop even if carrying zero.
Walk over the drop to recover it once. Respawn resets enemies and combat resources
but preserves in-memory bells, lift and reliquary. Closing the process loses all
progress in this build; portable persistence is not implemented yet.

See [PROGRESS.md](PROGRESS.md) for checks actually run and [FRICTION.md](FRICTION.md)
for framework observations. Test passage alone does not establish game polish,
play duration, enjoyment, renderer parity or hardware compatibility.
