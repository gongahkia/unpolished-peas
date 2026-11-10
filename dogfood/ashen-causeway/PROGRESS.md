# Development evidence

2026-11-10. In development; completion gates in DESIGN.md remain open.

## Verified now

Zig 0.15.2 on local macOS, base framework revision 1d202e9f:

```
zig test dogfood/ashen-causeway/src/combat.zig
zig test dogfood/ashen-causeway/src/combat.zig -O ReleaseFast
```

Both passed all four tests. Tests inspect every tick of both attack types for
both weapons, per-target damage-once masks, dodge boundary ages, damage-immunity
expiry, pending-input expiry and consumption at recovery completion, equipment
rejection while committed, healing timing/interruption, stamina rejection and
regeneration at heal recovery completion. These are game-rule unit tests, not
GameProtocol integration, collision, input-device or gameplay validation.

The initial healing test expected regeneration one tick later than the declared
idle policy. It now checks zero at age 59 and one at completion age 60.

## Remaining work

- Finish prerequisite reading, including complete audit follow-ups, guides and
  reference sources where the initial inspection only covered excerpts.
- Public consumer build and GameProtocol shell; actual input/facing/collision.
- World, encounters, four AI types, two-phase boss, checkpoints, shortcut,
  exploration rewards, upgrades, death/drop/recovery and complete ending.
- Original art/audio, authored text, all screens, tutorial and accessible cues.
- Versioned portable saves/settings and failure handling with reload checks.
- Integration and full-route deterministic tests; external consumer builds.
- Real native/browser interaction and capture review, polish iterations,
  performance/resource measurements and required portable browser matrix.
- GUIDE.md, dated assessment, evidence links and final completion audit.

No native window, browser build, playthrough, duration measurement, visual
review, performance profile or physical controller check has been performed for
this game. No engine defect/fix is claimed. Existing README files are unchanged.

## World and host integration — 2026-11-10

The later evidence here supersedes the earlier unverified-build statements.
Implemented game-owned collision with movement substeps and wall-occluded attack
checks, three room layouts, bell gates, lantern rest/respawn, a bidirectional lift,
a reliquary and currency drop/recovery. Added prototype AI and a boss transition;
Censer projectiles, distinct boss-phase mechanics, upgrades and ending remain open.
Normal input now drives GameProtocol through public package modules. ActionMap is
allocated at init and released at deinit; bounded world state owns no allocations.

From `dogfood/ashen-causeway`:

```
zig build test web -j2 --summary all
zig build run -- --frames 120
```

The first command passed all 15 build steps and 11 tests (including imported
coverage). The second exited successfully after 120 native frames, reporting
Cocoa/SDL GPU/MSL, audio ready, 480×270 canvas and 1920×1080 framebuffer on this
Intel macOS host. This was a bounded title-screen run, not a native playthrough.

From the engine root, with the built web directory served on loopback port 8114:

```
PEAS_SMOKE_BROWSERS=chromium,firefox node dogfood/ashen-causeway/tools/browser-smoke.mjs
```

Chromium 157.0.8103.39 and Firefox 158.0 passed title → start → right movement →
weapon switch/light attack → pause using trusted browser keyboard events. The
script checked 480×270 dimensions, nonzero WebGL readback, GL error zero, changing
frame checksums and no page errors. It retained PNGs and JSON under
`dogfood/ashen-causeway/zig-out/evidence/`. Actual title/play/action captures were
visually inspected: this remains a sparse debug-font prototype needing authored
art, distinct silhouettes, richer telegraphs and UI work. Checksums are smoke
signals, not frozen parity references or game-state assertions. Safari and full
routes remain unverified. The Chromium check uses installed Chrome via the
existing authoring toolchain, matching its established adapter convention.

Additional deterministic coverage checks enemy anticipation, direction commitment,
one attack per victim, wall occlusion, boss transition immunity, room gates,
checkpoint resource resets, drop replacement/recovery, input-driven movement,
weapon switching, attacks, pause freezing and three complete host lifecycles with
the testing allocator. The boss test isolates the Warden so other active enemies
do not invalidate its no-damage transition assertion.

Remaining next priorities: finish prerequisite source/guide reading; projectiles
and boss phase mechanics; versioned saves and settings; meaningful upgrades and
optional equipment; a complete ending; authored audiovisual presentation and
polish; full-route input/replay evidence; outside-checkout archive consumer;
Safari/reloads/failure injection; measurements; dated assessment and final audit.

## Persistence, equipment and menus — 2026-11-10

Added explicit forty-byte `ASH1`/version-1 saves through the public SaveStore.
Byte fields and checksum exclude raw struct memory, clocks, health, active attacks
and enemy state. Continue restores the last checkpoint and full resources;
permanent progression, currency/drop, weapon/equipment, ending and settings persist.
Invalid data is rejected, kept intact and explained; only explicit New Game can
replace an unreadable slot. Rejected writes show a persistent warning and retain
old bytes. Settings edits before replacing an unreadable journey cannot overwrite
it. Pause Save/Retry permits another attempt without restarting.

Implemented three capped damage upgrades, three vitality upgrades, the optional
flask/charm reward and its stamina-versus-walking-speed tradeoff. Added menu flows
for title/Continue/New Game, settings, pause/upgrades, death, victory and credits.
After boss defeat, a second interaction at the third bell triggers the beacon
ending. Full-route reachability and boss phase-two shock rings remain open.
Settings preferences persist; audio/flash/shake output remains pending, as the
guide states. This is not a finished audiovisual experience.

The browser smoke script now verifies actual reload/Continue, inspects the saved
weapon byte, rejects writes by temporarily throwing from localStorage.setItem,
checks exact preservation of the old value, then restores storage and retries
through the real pause menu. Chromium 157.0.8103.39 and Firefox 158.0 passed,
including nonzero WebGL readback, zero GL errors and no page errors. Save-failure
PNG inspection confirmed the warning was visible above gameplay. Art remains
prototype geometry and debug text. Browser matrix reports/PNGs remain under
`zig-out/evidence` in the game directory. This is not full gameplay/renderer parity
or Safari/native-reload evidence.

The first browser retry assertion sent pause/down/confirm within one fixed tick.
The host correctly accumulated the input; the game entered pause and did not also
execute a second menu action in that update. The harness now spaces trusted key
commands over ticks, following the existing authoring adapter's cadence. This is
a tooling correction, not a demonstrated framework defect.

Final checks for this tranche, from the game directory:

```
zig build test web -j2 --summary all
zig build test -Doptimize=ReleaseFast -j2 --summary all
```

Both passed 17 tests; Debug/web completed all 15 build steps and ReleaseFast all
7. Coverage includes save round trips and transient resets, every truncated
length and single-byte mutation, invalid fields with a recomputed checksum,
failed-write preservation/retry and visible-warning drawing, corrupt-save
retention, New Game settings preservation, all menu draw states, capped upgrade
spending/capacities, charm mobility tradeoff and beacon victory gating. These
fixture tests do not stand in for a complete normal-input winning route.

## Enemy mechanics and combat feedback — 2026-11-10

Censer shots now move with locked aim instead of applying instant beam damage.
The Warden alternates second-phase cleaves with anticipated expanding shocks,
after its safe transition and recovery. World-owned fixed arrays cap shots at
32 and rings at four; pools skip spawns when full, never replace live hazards,
and clear at checkpoints/respawns/transitions. Saves explicitly exclude them.
Pike thrust/Hound bite corridors now differ from Drifter/Warden cleave fans.
DESIGN.md records the actual timing, extent, damage, dodge crossing and reset rules.
A stress regression exposed a repeat-stagger game bug; an old-guard reproduction
fails and the revised guard passes. See FRICTION.md for evidence and classification.

Replaced letter-labelled enemy circles with distinct bodies, anticipation/recovery
poses and outlined threat regions, plus health bars and phase/attack cues. Browser
keyboard interactions reached a live Reed Quay encounter. Captures of anticipation,
release and player attack/dodge were inspected: the Drifter fan was visibly ahead
of its body and the Pike had a distinct tall silhouette and thrust corridor.
A Hound anticipation outline includes its forthcoming dash distance. Typography,
environment detail, full boss capture review and final visual polish remain open.

Added original generated score and seven cues, separately controlled volumes,
optional hurt flash/camera shake (off by default), expired/rejected-action feedback,
and a new-journey contextual control tutorial. tools/generate_audio.py retains
all source; assets/PROVENANCE.txt records origin without choosing a license.
The public Audio source handles are explicitly unloaded at shutdown. Readiness
retry allows browser autoplay recovery after input. Native test coverage checks
source decoding, volume-zero silence, finite nonzero mixed samples, release and
stale-handle rejection across three content cycles.

Commands from the game directory:

```
zig build test web -j2 --summary all
zig build test run -Doptimize=ReleaseFast -j2 --summary all -- --frames 120
```

At the audio integration checkpoint these passed 26 tests; all 15 Debug/web and
10 optimized test/native-run steps succeeded. The bounded native run selected
Cocoa/SDL GPU/MSL and exited normally. It was a launch/cleanup check, not a native
winning route or speaker evaluation. Follow-up UI tutorial edits are checked
separately before commit.

The browser script (same command as above) now imports the existing authoring
instrumentation and asserts finite nonzero PCM accepted by WebAudio after trusted
input, alongside readbacks, save/reload/rejection/retry and encounter captures.
Chromium 157.0.8103.39 accepted 457 nonzero submissions; Firefox 158.0 accepted
450 nonzero submissions out of 452 in this run, with zero invalid PCM or page
errors. Counts depend on scheduling. These establish submission, not listening
quality, native speaker output, broad performance or a complete playthrough.

## Complete deterministic routes — 2026-11-10

Added a game-owned test pilot in src/route.zig and input translation in
src/route_protocol.zig. The pilot only observes state and supplies ordinary
commands/input snapshots. Winning routes never teleport, grant currency,
replenish resources, set progression flags or delete enemies. Its fixed-capacity
BFS is automation-only; player navigation remains manual.

Both keyboard/mouse and virtual-controller GameProtocol routes now complete:
opening → first bell → Cloister checkpoint → real pause-menu weapon upgrade →
optional flask/charm reliquary → second bell → return lift both ways → Crown
checkpoint → both Warden phases and a shock → third bell → beacon ending.
Each route records public replay input, then runs that fixed input on a fresh
runner with no adaptive pilot. Ending save bytes and final Canvas traces match.
A separate route earns embers, deliberately refuses attacks/dodges until killed,
uses the death-screen input to respawn, observes restored resources/enemies and
recovers the nonzero drop through normal input. A new runner also loads each
winning save and confirms boss/ending/equipment progression.

Exact command from the game directory:

```
ASHEN_ROUTE_EVIDENCE=zig-out/evidence/routes zig build test -j2 --summary all
zig build test -Doptimize=ReleaseFast -j2 --summary all
```

Both passed 29 tests. Captures and encoded public UPR files are retained under
`zig-out/evidence/routes` for both input modes. Warden anticipation, phase
transition, shock and ending PNGs were inspected. These are actual headless
GameProtocol gameplay captures, not native GPU/browser screenshots. Complete
winning routes on native/browser hosts remain to be verified. Virtual-controller
coverage does not establish physical-controller compatibility.

The expert automation's route is roughly 105–110 seconds of simulated input,
plus small menu/start overhead; the shorter world-only route takes about 87
seconds and omits the lift/checkpoint/upgrade detour. Neither establishes a first
human successful-playthrough duration. The original 15–30 minute target remains
unverified, and pacing/content review remains required; do not present these
runs as evidence that the target is met or that the game is polished/enjoyable.

Route work also tightened movement ActionMap axis thresholds to 0.15 so modest
stick components retain directional precision. It exposed a victory recovery
problem: the screen claimed a saved ending even on a failed write and had no
retry. It now displays the actual status and accepts Escape/Start to retry.
The existing rejected-write test now verifies this final-screen recovery too.

Current remaining gates after a69e14b4/a77bb9f2: authored text and environment/UI
polish, encounter/pacing assessment against the first-run duration target, real
native/browser complete-route and reload verification (including Safari),
external archive consumer builds/runs, representative performance/allocation
measurement, remaining prerequisite/reference review, and the dated assessment
plus final requirement-by-requirement completion audit. Passing these headless
routes does not close those gates.
