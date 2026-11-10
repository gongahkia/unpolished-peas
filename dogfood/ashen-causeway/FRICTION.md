# Ashen Causeway — framework friction

Started 2026-11-10 at engine revision 1d202e9f. This is the canonical report.
No engine defect has been demonstrated yet. The game is in development; this
report does not certify complete gameplay or platform validation.

## Observations

- Fixed-tick, game-owned combat is ordinary Zig and can be tested without a
  window. No RPG subsystem is requested from Peas.
- Existing starter and dogfood projects provide public package build recipes,
  portable save blobs, authored text and explicit audio cleanup. Integration
  of those recipes into this game remains to be verified.

## Required issue record

For each demonstrated significant issue retain task, exact reproduction command,
platform/toolchain/build/revision, expected and observed result, API/source
locations, logs/captures/minimal reproduction, classification, severity/impact,
workaround and cost, proposed improvement, resolution/regression and final status.
Do not promote untested expectations into framework defects.

## Verified facilities — 2026-11-10

At game base aea32d01 with Zig 0.15.2/Debug on Intel macOS, the generated starter
build recipe accepted this game through `unpolished-peas` and
`unpolished-peas-sdl3`, and its browser-core/runtime package modules. Reproduction:
`cd dogfood/ashen-causeway` then `zig build test web -j2 --summary all`.
Observed: 11 tests and the Wasm build pass; a 120-frame native run succeeds.
Physical-key/pointer/controller ActionMap bindings required no backend imports.
Headless GameProtocol cleanup exercised three lifecycles with the test allocator.
Classification: facilities working as documented; no workaround or engine change.
See PROGRESS.md for browser readback smoke evidence and its limits.

## Save integration — 2026-11-10

Task: persist a complete RPG checkpoint/equipment record and recover after rejected
writes. Reproduce from the game directory with `zig build test web -j2`, serve
`zig-out/web` on loopback port 8114 and run from the engine root:
`PEAS_SMOKE_BROWSERS=chromium,firefox node dogfood/ashen-causeway/tools/browser-smoke.mjs`.
Context: Intel macOS, Zig 0.15.2, native Debug/browser ReleaseSmall, base c09375b1.
Public APIs: GameContext.save_data, SaveStore.read/write, InMemorySaveStore;
game sources: src/save.zig and Game.load/persist in src/game.zig.
Expected/observed: a failed replacement retains the good blob, reads and retry
continue to work. Native allocator-failure tests and real Chromium/Firefox quota
injection confirmed this behavior; actual reload restored the selected weapon.
Evidence: game zig-out/evidence/browser-smoke.json and save-failed PNGs, plus the
deterministic tests. Category: supported facility working as documented; severity
none, workaround/cost none. Game-owned byte encoding, validation and warning UI
remain ordinary authoring responsibilities. No serialization engine is proposed.
