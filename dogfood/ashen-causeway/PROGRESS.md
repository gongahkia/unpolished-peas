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
