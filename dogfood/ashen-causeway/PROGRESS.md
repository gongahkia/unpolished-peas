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

## Authored UI and navigation presentation — 2026-11-10

Replaced debug-font output with embedded Source Sans 3. Both faces and reusable
body/heading layouts load through public AssetCollection/Font APIs during init;
cleanup releases layouts before fonts, including partial-init failures. Numeric
HUD values draw without allocation in fixed columns. All static catalog entries
and headings fit their logical width budgets. The original Adobe font notice
is copied unchanged and verified in native/web assets. No repository license or
existing README was changed.

Added lantern/bell/lift/reliquary silhouettes and interaction labels, an off-screen
objective marker, distinct Quay/Cloister/Crown floor treatments, player walk/dodge
poses, and a weapon swing outline tied to the active window. These additions do
not introduce new solid walls or change combat timing. Helpers borrow Game by
pointer so preparing text does not create large per-primitive Game copies.
Menu spacing and settings selection account for authored line height. Captured
reviews found and corrected a heading style accidentally applied to the Settings
menu item, a rest label touching the player, and generic footer instructions on
screens where they did not apply. Selection backgrounds were darkened for contrast.

From the game directory:

```
ASHEN_ROUTE_EVIDENCE=zig-out/evidence/routes zig build test web -j2 --summary all
zig build test package -Doptimize=ReleaseFast -j2 --summary all
```

The Debug/web command passes all 15 steps and 31 tests, including both complete
input/replay routes, exhaustive text initialization failure handling, static copy
width checks and allocation-free prepared/direct text drawing. Optimized testing
and packaging are rerun after the final layout corrections before commit.

From the engine root with the built web bundle on port 8114:

```
PEAS_SMOKE_BROWSERS=chromium,firefox node dogfood/ashen-causeway/tools/browser-smoke.mjs
node dogfood/ashen-causeway/tools/safari-smoke.mjs
```

Chromium 157 and Firefox 158 pass the expanded title/settings/credits and encounter
captures, save reload/rejected-write/retry and finite nonzero WebAudio checks.
Real Safari 18.6 passes independent and game WebGL red-pixel probes, trusted menu
input, weapon/settings persistence after actual reload, and audio activation.
Safari PNG capture was independently available. Safari screenshots of the title,
settings and continued game were inspected; strict readback checks were retained.
The task-owned WebDriver service and session were stopped afterwards. The Safari
harness preserves a prior journey at the loopback origin. Its menu commands are
spaced over fixed updates; its initial rapid-key loop skipped a selection, so the
harness now waits after each release. No engine defect is inferred from that.

These are portable UI workflows, not complete native/browser winning routes or
full pixel parity. Broader renderer requirements, tolerances and physical IME
limitations are unchanged. The remaining goal gates still include pacing/content
review, full real-host routes/reloads, archive consumers, performance/allocation
profiles, prerequisite/reference review and the dated final assessment.

Presentation review: full mode, scoped to the current 480×270 Canvas UI and visible
Quay/Cloister/Crown route captures. Styling remains game-owned Zig primitives and
prepared authored text; no second UI/rendering system was added.

| Category | Evidence inspected | Result |
| --- | --- | --- |
| Typography | src/typography.zig; title, settings, credits, boss and ending captures | Authored sizes, fixed HUD columns, body/heading distinction and width checks implemented |
| Surfaces | Menu panels, selected rows, wall/floor/shore primitives | Consistent palette and darker selection fill; no new collision implied |
| Animation | Fixed-update player walk/dodge and attack poses; encounter phase captures | State cues reviewed; continuous motion at 10% speed remains unverified (Canvas has no CSS animation track) |
| Icons | Lantern, bell, lift, chest, objective diamond and weapon geometry | Distinct shapes and textual cues added; none relies solely on color |
| Performance | Allocation-failure and allocation-free text draw tests; helper signatures | Text ownership verified; whole-game frame time and allocation profile remain open |

| Severity before change | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| Medium | src/typography.zig; Game.draw | Small debug glyphs throughout | Authored body/heading layouts prepared in init | Legibility and hierarchy |
| Medium | src/game.zig HUD | Counters shared one shifting formatted row | Fixed counter columns and normalized bars | Stable numeric information |
| Medium | Game.scenery / compass | Anonymous circles and off-screen objectives | Landmark silhouettes, interaction labels and edge marker | Discoverability and icon clarity |
| Low | Game.draw menus | Heading style reused for a menu item; rest text touched player | Explicit heading context and adjusted rest label | Consistent scale and optical spacing |
| Low | Game.draw world/player | Uniform floor and circular player | Area floor treatments, cloak/head, committed weapon pose | Cohesion and state readability |
| Low | Game.draw menu footer | Gameplay/tutorial hints remained under every screen | Contextual menu/ending instructions | Relevant, understandable feedback |

Considered and rejected: full-screen bitmap scenery would add a second asset
workflow for detail already expressible with the existing Canvas palette; shader
glow was unnecessary for the readable landmark silhouettes and would introduce
an optional rendering dependency. Menu entrance staggering was also omitted to
keep frequent pause interactions immediate.

Verification is the exact commands and captures recorded above. Provisional
verdict: needs further review. Full real-host route/motion review and whole-game
profiling are unverified; this is not approval of the entire game's polish or
pacing.

Final optimized rerun after the heading/selection corrections: all 12 test/package
steps and 31 tests passed. Final Debug/web rerun: all 15 steps and 31 tests passed.


## 2026-11-10 — archive consumer and complete real-host routes

Game baseline 665bb036; no gameplay changes in this verification increment.
`python3 script/test_ashen_causeway_external.py` passed from a fresh consumer
cache outside the checkout, with a real loopback archive fetch and computed Zig
package hash. The copied game passed 31 tests, native packaging and a 120-frame
SDL launch, plus browser compilation. Authored source hashes and retained notices
were checked. `zig-out/diagnostics/ashen-external/result.json` records archive
SHA256, tree daf5c2468761f69bc8598a10c3deec6930206483, commands and output hashes.
The later optional verification build steps were added after that archive snapshot;
this run establishes the production game/public package boundary at the stated tree.

`python3 script/test_ashen_causeway_native.py` passed a real SDL journey with
6,577 normalized keyboard/mouse updates, checkpoint 2, upgrade 1 and ending saved,
then a new process loaded boss defeat, equipment and full checkpoint resources.
Both processes verified audio playback cleanup. Native ReleaseFast/Zig 0.15.2,
Intel macOS, SDL GPU/MSL, 1920×1080 framebuffer and 480×270 logical Canvas.
Evidence: `zig-out/diagnostics/ashen-native/result.json`, route/continue logs and
six PNGs. Boss windup/shock and continued-ending captures from real SDL callbacks were reviewed;
these are CPU Canvas captures, not native GPU readback or physical input testing.
The initial run suppressed the app-data path log, so its exact disposable UUID
namespace was removed manually after success. The helper now enables that log
and guards automatic cleanup by the reported parent and exact generated UUID.

After exporting the same public replay via `zig build export-browser-replay`
(the exact command is in GUIDE), ran:

```
UP_SAFARI_WEBDRIVER_URL=http://127.0.0.1:41245 node dogfood/ashen-causeway/tools/browser-route.mjs --browsers chromium,firefox,safari
```

Chromium 157.0.8103.39, Firefox 158.0 and real Safari 18.6 passed the complete
6,577-update route using the archive-built Wasm, then reloaded and continued the
completed save. Each passed five route milestone readbacks plus the continued
frame, comparing all 480×270 RGBA channels to native CPU references with tolerance
1. Independent strict red-pixel probes, ready WebGL2 diagnostics, zero protocol
failures and unchanged bundle SHA were required. Reports and captures:
`zig-out/diagnostics/ashen-browser-route`. The Safari shock capture was visually
reviewed after the run; windup/shock and ending were also reviewed from
the SDL run. The owned Safari service was stopped. Test-origin saves were restored.

The browser replay advances synthetic RAF timestamps and injects normalized
snapshots through the existing input wire ABI. It is real Wasm/renderer/storage
integration, not trusted physical input or performance evidence. Earlier browser
smokes cover trusted keyboard/pointer/audio separately. No renderer tolerances or
physical IME claims changed. The public replay bridge's maintenance cost is
recorded in FRICTION. Pacing, continuous motion review, whole-game profiling,
reference review and final assessment remain open; tests do not establish polish.

## 2026-11-10 — measured CPU resources and SDL presentation

Added optional profiling helpers, reusing public HeadlessGameRunner and the
existing native timing reporter/counting-allocator pattern. Three complete CPU
routes and six serial SDL windows passed. Full measurements, exact commands,
workload/hardware and limits are in PROFILE.md. Headless draws and audio mixing
allocate zero times throughout each route; updates make 31 requests totaling
2,530 bytes after init. Peak tracked live bytes are 1,922,822 and return to zero
after cleanup on every run. No whole-game zero-allocation claim is made.

Native 480×270 Canvas / 1920×1080 output, ReleaseFast on Intel i5/Iris Plus:
ordinary draw medians 0.209–0.237 ms, phase-two/shock 0.303–0.369 ms. Presented-frame
medians 16.649–16.677 ms include swapchain pacing; all retained frames have both
render passes. No GPU-completion or browser-performance measurement is inferred.
An isolated 14.487 ms native update aggregate remains unattributed. No bottleneck
justifies a rendering redesign. The exact disposable profile namespace was removed
by the guarded helper and its absence checked after the run.

## 2026-11-10 — slowed combat presentation sample

`node dogfood/ashen-causeway/tools/browser-route.mjs --browsers chromium --motion --output zig-out/diagnostics/ashen-motion-review`
passed the full archive-built route, six strict reference comparisons and ending
reload again. The optional test-only mode steps one simulation tick per 166.7 ms
wall delay through ticks [5580,5660) and [6250,6330), capturing every ten ticks.
The 16 full-frame readbacks sample approach/windup and dodge/shock expansion at
nominal 10% playback speed (capture adds extra wall delay). No shipping changes.

Viewed captures 5580/5630: player approach/camera position and the boss silhouette
remain readable; the fan outline precedes release with a raised anticipation
pose. Viewed 6260/6290/6320: dashed reach boundaries plus named shock cue precede
the moving bright band; the player changes to a crouched dodge pose, crosses into
the safe center, and the band continues outward without a damage flash. HUD and
boss label retain stable positions through the sequence. This is sampled automated
visual review, not physical/manual play or an inspection of every animation.
Healing/stagger and every archetype's continuous motion are not covered by these
two slow excerpts. No additional presentation defect was demonstrated here.

Presentation review remains provisional for the complete game pending the final
encounter/pacing assessment. Resource/CPU measurements are now recorded in
PROFILE.md; no universal performance or enjoyment claim follows.

## 2026-11-10 — reference review and current assessment

Completed the previously partial review of the October23 audit, November4 audit
and November9 consolidation, November7 rendering/chess, November8 composition and
November 10 diagnostics follow-ups. Read the current quickstart/installation,
authoring compatibility inventory, GameProtocol, rendering, input, asset/image,
authored-text, sprite-animation, audio/lifetime, saves, testing, browser-authoring
and diagnostics guides. Completed Seed Sprint's game/wrapper, both dogfood game
sources/art, Lantern Leap's level, both friction reports and their external
archive shell arrangements. Existing benchmark/headless/browser adapter and
packaging infrastructure informs the verification tools rather than a second
framework. This is a late completion of prerequisite review, not a claim that
those full documents had been read before initial implementation.

No additional engine change was justified by that review. Added a dated current
integration assessment with clear unfinished pacing/polish status and specific
limits. Corrected the design's unimplemented adaptive-music wording to the actual
persistent ambient score plus combat cues; no required audio feature is removed.
Retained PROFILE/assessment in the game package manifest so GUIDE links survive
packaging. No README, license, renderer contract or platform support status changed.

## 2026-11-10 — accepted-action pose review

Source/ordinary-input review found healing had no distinct player pose during its
60-tick vulnerable commitment. Added a held vial and slight crouch, then a small
cross at age 36 (the existing heal tick), clearing at recovery completion. Attack
startup now visibly draws the weapon back and raises the player pose before the
existing active reach/trail. No combat, progression or input timing changed.

`ASHEN_POSE_EVIDENCE=zig-out/evidence/poses zig build test web -j2 --summary all`
passed 32 tests and all 15 steps. After moving the capture sequence a short distance
from the lantern, `ASHEN_POSE_EVIDENCE=zig-out/evidence/poses zig build test -j2 --summary all`
passed 32 tests/all 7 steps. Reviewed healing-hold, healing-release, sabre-startup
and sabre-active actual CPU captures; the cue reads separately from the lantern.
The regression hashes only a small player region, so a changing flask HUD cannot
mask a missing pose. It also checks the cue at 36 and return to idle at 60.

The external consumer rerun before this visual-only increment also passed against
54de0808/tree a3a5f5d1b514d0c8a1355a26cb31cfd4b1888aae, with 31 tests. Its exact report is root
`zig-out/diagnostics/ashen-external-final/result.json`; production Wasm matched the
earlier archive hash. Updated pose references have now been exported; real-host
validation of the new presentation is the next check.

Regression discrimination: copied the current game into a temporary project,
restored 54de0808's Game rendering while retaining the new ordinary-input pose
test, and ran `zig build test -j2 --summary all`. It failed specifically at
`idle != holding`; current rendering passes. The retained failed-test log is
root `zig-out/diagnostics/ashen-pose-regression/before.log`. The temporary copy
used a canonical relative public package dependency and was removed. Two earlier
ad-hoc probe attempts stopped at malformed path configuration before running tests;
neither is evidence of a rendering failure or engine defect.

## 2026-11-10 — explain unavailable upgrades in pause

The pause menu hid the world-status row, and lantern/charm prerequisite guards
returned silently. Added explicit reasons and a second visible pause-footer row,
so successful, capped, unaffordable and prerequisite outcomes remain readable.
A new normal-input test leaves the lantern, opens pause, selects Weapon Upgrade,
checks the reason and unchanged level, then verifies visible message pixels.
Reviewed `zig-out/evidence/poses/upgrade-away.png`; controls and reason fit on
separate lines. Existing world tests now check guard explanations too.

The static label extractor previously included test names as prepared UI copy.
It now follows the modules' production-before-tests convention and excludes those
names, retaining all actual labels. This removes unnecessary initialization
storage; it is not an engine asset issue or a new runtime text system. The Debug
`test web` command above passed 33 tests/all 15 steps before that catalog cleanup;
its final rerun after cleanup is recorded next.

Final post-catalog rerun: 33/33 tests and 15/15 test/web steps passed. Full input
route tick counts remain 6,577 keyboard/mouse and 6,320 virtual controller.

## 2026-11-10 — action/menu studies and actual death-route captures

Added opt-in captures to existing tests (no new runtime fixtures or test count).
The ordinary earned-currency → death → respawn → recovery test now retains all
three relevant frames under ASHEN_ROUTE_EVIDENCE. Reviewed them: actual death
shows HP 0 and the drop-loss explanation; respawn restores 100 HP/three flasks and
shows the distant ember drop; recovery clears the drop and reports recovered
currency (75 embers including enemies defeated en route).

ASHEN_POSE_EVIDENCE additionally captures all menu fixtures and isolated enemy
windup, release, strike and recovery states. These arranged studies are labeled
as fixtures; they do not replace the complete ordinary-input routes. Reviewed
Pike windup's narrow corridor, Drifter strike fan, Censer anticipation/moving shot,
Hound charge, Warden recovery/player damage and the death panel. Corrected the
Hound fixture to its actual 60 HP, and kept the boss in its normal slot so the
study HUD does not imply a missing Warden. No production rules/art changed.

From the game directory:

```
ASHEN_ROUTE_EVIDENCE=zig-out/evidence/routes ASHEN_POSE_EVIDENCE=zig-out/evidence/poses zig build test -j2 --summary all
```

Result: all 7 steps and 33 tests pass. Optimized tests/package/new browser references
also passed all 15 steps/33 tests before these test-only capture helpers. The fresh
archive-consumer run at b26b9651/tree a0395289089868f891e6f5d78bf46d68da9d5352 passed
all four commands; root `zig-out/diagnostics/ashen-external/result.json` retains
this latest production bundle/hash. Full SDL presentation/reload verification is
running against this presentation increment; final browser rerun follows it.

## 2026-11-10 — truthful title after persistence and refreshed host proof

Successful writes now clear stale corruption/missing-save title text; failed
writes still retain the old explanation/data. Settings-only success has its own
status. The corrupt-slot test asserts cleared load_problem and the accurate
Continue note after explicit New Game. All 33 tests and 15 test/web steps pass.

With the current web build served on 8114, ran the trusted browser smoke in both
Chromium 157.0.8103.39 and Firefox 158.0. Existing input/settings/reload/rejected-
write/retry and finite nonzero audio checks pass; the new corrupt slot → explicit
New Game → title → actual reload/Continue route passes too. Reviewed both corrupt
and replacement title captures. A changed checksum alone is not proof of exact
copy; the game regression checks the actual note. Evidence: game
`zig-out/evidence/browser-smoke.json`, PNGs, and root
`zig-out/diagnostics/ashen-persistence-polish.log`.

The preceding complete SDL rerun also passed at the new pose/pause presentation:
`python3 script/test_ashen_causeway_native.py --output zig-out/diagnostics/ashen-native-polish`.
Both route and new-process Continue verify ending/progression and audio cleanup;
the generated UUID save directory was confirmed removed by the guarded helper.
That run precedes this title-copy-only fix. The root `zig build test-docs docs -Dwith_sdl=false -j2 --summary all`
check passed 43 steps/36 tests, including API/asset/font/audio/replay recipe checks.
Its printed invalid-link/stale-reference messages belong to negative fixtures.

## 2026-11-10 — command acceptance feedback

An E press with no object played the interaction bell, and a weapon swap during
commitment failed silently. World.tick now reports successful interactions through
a transient acceptance flag, gives reasons for unavailable E/swap commands and
uses the existing rejected-action cue. The flag clears on every tick, including
an early dead-player return; Game plays the bell only on success. No combat
window, movement speed, damage, cancellation or save-byte policy changed.

A focused rule regression covers empty/committed interactions, committed swap
without changing weapon, valid lantern use and stale acceptance clearing. The
first Debug/web run passed 34 tests/all 15 steps; the final acceptance-flag rerun
also passes as recorded below. Complete keyboard/controller route tick counts
remain 6,577/6,320. This closes the final command-feedback review finding before
refreshing the complete host checks and measured resource observations.

Final acceptance-flag rerun: 34/34 tests and 15/15 test/web steps passed.

## 2026-11-10 — final host, shutdown and resource evidence

Production source 50511dde's fresh external archive consumer passes all 34 tests,
package/web and a 120-frame native launch, with authored sources unchanged and
notices retained. Actual tree 51f7664c69812efd5bd7729fcb652ac1de655992 and Wasm
SHA256 6bfa7dc86962f2dbe0b2026f0eddc6bd40c2170942cf69302f9978f105191790
are recorded in root `zig-out/diagnostics/ashen-external/result.json`.

`python3 script/test_ashen_causeway_native.py --output zig-out/diagnostics/ashen-native-final`
passes the complete 6,577-update route and actual second-process Continue with
ending/progression verified and audio cleanup. Its exact UUID directory is
removed by the guarded helper. No native GPU-readback claim is made.

`UP_SAFARI_WEBDRIVER_URL=http://127.0.0.1:41245 node dogfood/ashen-causeway/tools/browser-route.mjs --browsers chromium,firefox,safari`
passes in Chrome 157.0.8103.39, Firefox 158.0 and real Safari 18.6. Each completes
and reloads the ending, passes six strict full-frame comparisons at tolerance 1,
then explicitly calls the real runtime shutdown. All three report protocol
failure=-1, game GPU resources=0, scheduled frames=0 and host phase=destroyed;
test-origin saves are restored. Root report: `zig-out/diagnostics/ashen-browser-route/result.json`.
The owned Safari service was stopped after each pass.

Final profiling tools/optimized tests/package pass18 steps and 34 tests. A separate
one-round rerun passes full-route CPU and both SDL windows after disabling
observer progress I/O in profile mode. Current peak tracked live bytes 1,879,998,
cleanup 0, and unchanged 31 update requests/2,530 bytes, with zero draw/mix requests.
PROFILE.md retains current distributions and the 41.210 ms frame tail at input 555;
its cause remains unattributed. Game saves remain intentionally timed. No hard
frame guarantee or unsupported renderer optimization follows.


## 2026-11-11 — final review and handoff

The final verification reports were completed before midnight UTC+7 on November 10;
the handoff/review is dated November 11. ASSESSMENT-2026-11-11.md supersedes the
working assessment's provisional status, links final proof/limits and retains the
focused commit history. DESIGN/GUIDE now describe the reviewed playable build,
actual capacities and the explicit unmeasured 15–30 minute first-success target.
The fast expert route remains a substantial pacing risk, not a measured human
play duration. No external playtest, physical device check or subjective enjoyment
claim is manufactured to close that gap.

All mandatory systems and concrete native/browser integration checks are delivered.
The review used actual captures/interactions and corrected demonstrated feedback,
pose and state issues; test passage alone is not its presentation verdict. Open
replay-tooling and native-tail attribution observations remain in FRICTION. Final
README/notice/diff/format/link checks and the final documentation commit follow.
Owned Safari services and the task-owned loopback 8114 server are stopped; temporary
verification UUID directories are removed. The game guide contains fresh launch
commands rather than depending on a lingering server.

Handoff checks: source/ZON formatting and current diff checks pass; the final
manifest's every package path exists. Final ReleaseFast package passes 9/9 steps
(cached implementation). Final docs/link/recipe run passes 43/43 steps and 36/36
tests. Existing README diff against 1d202e9f is empty. The original Source Sans
notice remains verbatim, including its inherited whitespace. Final documentation
changes add the November 11 assessment to package paths and the non-README index.

## 2026-11-12 — shared browser replay tooling

Resolves the replay-tooling proposal in FRICTION while retaining its original
finding. No gameplay or frame-tail investigation is included. Starting checkout
c8f4cf7f was clean; toolchain is Zig 0.15.2 on Intel macOS. Existing README files
and notices remain unchanged.

`up.preview.developer.BrowserInput` now owns the existing Zig browser decoder
and an allocation-free v2 encoder. The browser decoder path delegates to that
codec. Exporters explicitly supply framebuffer size/focus/visibility (and optional
resize epoch), since normalized snapshots omit that metadata. No ABI/UPR version
change is introduced. The shared test-server `script/browser-authoring/replay.mjs`
owns input injection, RAF stepping and lifecycle. Ashen retains references,
milestones, seed/initial-save policy, 60 Hz guard and game assertions. Ordinary
shipping execution never installs the driver.

Changed implementation: engine codec/public preview aliases and API snapshot;
Wasm/DOM input compatibility tests; shared replay driver/contract test and its
build target; game exporter/route; archive-consumer harness. Documentation:
FRICTION, GUIDE, this log and `docs/guides/testing.md`. The public-import fixture
was stale before this change (the existing Ashen sources were absent); the first
broad check failed only on that inventory. Regenerating it adds those 15 existing
source entries and the rerun passes, without weakening the compatibility check.

Exact commands from the engine root:

```sh
zig test src/browser_input.zig
node script/browser-authoring/replay.test.mjs
zig build test test-browser-input-v2 test-browser-replay-driver test-core-api test-docs -Dwith_sdl=false -j2 --summary all
zig build test-browser-input test-browser-input-v2 test-browser-replay-driver test-replays test-core-api test-docs test-web-package -Dwith_sdl=false -j2 --summary all
python3 script/test_ashen_causeway_external.py --output zig-out/diagnostics/ashen-replay-adapter-external-final
```

Results: standalone codec/imported input tests 17/17; shared driver contracts
pass; broad build 85/85 steps and 328/328 tests; final compatibility/docs/web
package build 54/54 steps and 43/43 tests. Logs:
`zig-out/diagnostics/replay-{codec-tests,adapter-checks,adapter-final-checks}.log`.
The independent JS DOM producer/Wasm test checks all wire bytes, allowing only
ignored null-canvas coordinates to canonicalize to zero. It includes four
controller identities and current/previous axes, pointer edges, physical keys,
Unicode text/composition and existing replay/zero-update/catch-up fixtures.
Driver contracts cover capacity and memory bounds without consumption, malformed
size/HTTP errors, exhaustion, no repeated edges, cancellation within a RAF batch,
pending-load disposal, streaming fallback, wrapper restoration and reinstallation.

The final external consumer passes all 34 game tests, optional exporter, ordinary
package/web and a 120-frame native launch; authored sources and notices survive.
It verifies the shipping JS/HTML has no replay instrumentation and retains the
exported wire/references beside its unmodified web artifact. Actual source tree
`0eb1f2b7b93441db949a5ce051be9c2a00ff7d1d` (a worktree archive over c8f4cf7f)
and hashes are in `zig-out/diagnostics/ashen-replay-adapter-external-final/result.json`.
The first archive-consumer run also passed; its separate report remains in
`zig-out/diagnostics/ashen-replay-adapter-external`.

Real-browser reproduction uses the bundle and input from that same final
consumer. Start the Safari service in a separate terminal and stop that owned
process after the route finishes:

```sh
safaridriver -p 41245
UP_SAFARI_WEBDRIVER_URL=http://127.0.0.1:41245 node dogfood/ashen-causeway/tools/browser-route.mjs --bundle zig-out/diagnostics/ashen-replay-adapter-external-final/web --input zig-out/diagnostics/ashen-replay-adapter-external-final/browser-route-input --output zig-out/diagnostics/ashen-replay-adapter-browser-final --browsers chromium,firefox,safari
```

Wasm SHA256 remains
`6bfa7dc86962f2dbe0b2026f0eddc6bd40c2170942cf69302f9978f105191790`;
wire SHA256 is
`1403bf02521403f569bbc8ba0400cc374d0e8f5dc7695ad5c5319cafd1f3385f`.

Final result: Chromium 157.0.8103.52, Firefox 158.0 and real Safari 18.6 all pass
the complete 6,577-tick route, ending progression/save reload and six reference
comparisons per browser (five route frames and continued). Every RGBA channel is
within the unchanged tolerance 1 of the native CPU reference. Existing strict
independent/game WebGL probes pass. All report failure=-1, resources=0,
scheduledFrames=0, phase=destroyed and originalSaveRestored=true. Result/captures:
`zig-out/diagnostics/ashen-replay-adapter-browser-final`; the earlier three-browser
pass remains in `zig-out/diagnostics/ashen-replay-adapter-browser`. The owned
Safari service and test servers are stopped. Final docs/driver recheck passes
42/42 steps and 36/36 tests (`replay-adapter-docs-final.log` under root diagnostics).
Formatting and diff checks pass; README changes against c8f4cf7f are empty.

Limits remain explicit: roughly 12 MB of expanded test input, game-owned
initialization and deterministic behavior, synthetic timestamps and normalized
input only. This verifies neither physical/trusted input nor human pacing or
frame performance; the native frame-tail investigation stays open. No source
archive was published, no license was chosen or changed, and no deployment or
push was performed.

Implementation commits: `92e223de` (canonical codec/public compatibility) and
`1a67647f` (shared driver, migration and archive verification).

## 2026-11-12 — bounded native save/update attribution

Read the attached goal objective and began at clean d6441b09, preserving all
completed replay work and historical `ashen-profile-polish` artifacts. The raw
historical frame is host index 254 with exactly one update, input tick 555:
40.598397 ms update/41.210248 ms frame. Its separate CPU sample is 0.021635 ms
with a 40-byte update allocation, which alone does not establish a native cause.

Added verification-only `profile_saves.zig` (bounded collector and transparent
SaveStore wrapper), `profile_state.zig` (untimed gameplay oracle digest) and
`profile_observer_bench.zig` (controlled overhead). Native verification optionally
observes real store operations, serializes after the loop and validates persisted
bytes. CPU profiling adds per-tick state/save oracles outside timed work. The
runner correlates host update counts to ticks, handles catch-up/zero updates,
retains failures/raw data/hashes, alternates modes and rejects report overwrite.
The optional build/test targets and public import inventory include these files.
No production game or persistence implementation changed.

PROFILE records exact commands, pooled/per-round distributions, write/residual
measurements and limitations; FRICTION records the final assessment. Fresh
report: root `zig-out/diagnostics/ashen-save-attribution-20261112/result.json`,
measured tree `5dce64208f850ffabc3abcd0f3682bad92c9718f`, Zig 0.15.2/ReleaseFast,
Intel i5-8279U/Iris Plus, macOS 15.7.7. Builds finished before the serial three
CPU routes and twelve SDL windows. Historical report hashes remain unchanged.

All cases pass presentation, no-drop and cleanup checks; all twelve native
endpoints match the CPU state/save oracle. The guarded UUID namespace is absent.
Across 2,880 retained frames, the 40.598 ms update tail does not recur; observed
tick-555 writes take 0.581–1.291 ms. A warm-up save takes 14.726 ms, and larger
warm-up frame tails remain in the raw evidence. The retained 36.431 ms maximum
is dominated by upload/present. No causal syscall/device attribution follows.
Measured no-op-store observer overhead is 0.149 µs extra median per update/write
pair; paired native median variation is larger. No extra experiment was used.

Checks: optimized build/game/observer 18 steps/66 tests; ordinary Debug test/
observer/web/package 23 steps/66 tests; root storage/core API/import inventory
10 steps/9 tests; three deterministic Python association tests. Exact commands
and logs are linked in PROFILE. The first optimized build failed on Zig local
name shadowing, was corrected before measuring and is retained in its separate
build log. No failed measurement is represented as a success.

Conclusion: historical update spike not reproduced, cause still unproven, no fix
justified. Keep actual save durability/error/replacement behavior. The concrete
next proposal is a bounded correlated scheduler/file-I/O trace if stalls recur,
with sub-operation markers before considering a persistence-policy tradeoff.
No README, license, replay adapter, deployment, publication or push changed.

Final untimed reporting review additionally preserves cleanup on report/read
errors and bounds short saved-byte reports. The verification-root deterministic
test covers missing/short blobs and resource release. Final optimized optional
build/observer tests pass 15 steps/33 tests, root persistence/API/inventory passes
10 steps/9 tests again, and docs/shared replay-driver passes 42 steps/36 tests.
The comparison's three exact executables are retained as `measured-binaries`
beside its report; measured-loop code is unchanged by this reporting hardening.
The failed initial cleanup-test AudioMixer type check is retained separately;
no failed build was used for measurements. Ordinary web Wasm still has SHA256
`6bfa7dc86962f2dbe0b2026f0eddc6bd40c2170942cf69302f9978f105191790`.

Diagnostic tooling commit: `2ed5c2a1`. There is no performance/storage fix commit,
because the bounded comparison did not justify one. Final completion audit
rechecked all twelve window results, three CPU routes, exact retained executable
hashes, preserved historical report hashes and absent test namespace.
The final docs-only check passes 40 steps/36 tests. Formatting/diff checks pass,
and README changes against d6441b09 are empty; no owned measurement processes
remain.
