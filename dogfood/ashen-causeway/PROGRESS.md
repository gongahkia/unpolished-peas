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
