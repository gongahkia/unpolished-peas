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

## Game combat interruption loop (resolved game bug)

Author task: make enemies stagger without allowing unlimited attack interruption.
Context: Intel macOS, Zig 0.15.2, Debug, baseline 5fea8558's 72-tick stagger guard;
relevant game API/source: Enemy.stagger_guard and World.tick in src/world.zig.
Expected: repeated light hits leave an enemy a chance to complete anticipation.
Observed: the guard expired before stagger + recovery + windup completed, so
repeated attacks could keep restarting anticipation. Severity medium, combat
fairness; classification game bug, not an engine defect or missing facility.

Regression: `zig test dogfood/ashen-causeway/src/world.zig --test-filter 'repeated light hits'`.
The stress fixture replenishes stamina/HP and holds positions to isolate combat
interruption; it is not a normal-input playthrough. A temporary copy of the
current world/combat modules with `e.stagger_guard = 180` replaced by `72` fails
that assertion (`saw_active` is false, exit 1). The current 180-tick version
passes. This gives the enemy enough resistance to complete an attack while
allowing initial stagger. No workaround/runtime facility or framework API is
needed; resolution is game-owned timing policy with this regression. Final
status: resolved in b57d06b1, subject to ordinary encounter play review.

## Combat presentation and audio facilities

The public Canvas lines/primitives express game-owned silhouettes and attack
regions without a renderer change. Public Audio.loadWav/loadMusic(.wav), play,
setMusicVolume, unloadSound and unloadMusic support an eight-second original
ambient score plus seven effects. Ownership is explicit in src/sound.zig;
scene/death resets retain reusable sources and shutdown releases them. The WAV
score is larger than OGG but small and reproducible without an external encoder
(352,844 encoded bytes). This is an asset choice, not a demonstrated engine gap.
No engine change is requested. Tests verify decoded sources, finite nonzero PCM,
zero-volume silence and stale handles after release across three cycles.

## Ending save recovery (resolved game bug)

Task: recover when the final progression write is rejected. Baseline c767c692,
Intel macOS/Zig 0.15.2, Debug/native headless GameProtocol. Expected: victory
accurately reports pending persistence and allows retry. Observed in code and
captured ending screen: unconditional "Your journey is saved" text; the victory
menu ignored the pause/save control. This was a medium-severity game UI/state-flow
bug, not a SaveStore defect. Sources: Game.menu's victory branch and Game.draw
in src/game.zig; the public SaveStore already retained good data on rejection.

Reproduce/check: `cd dogfood/ashen-causeway && zig build test -j2`. The rejected-
write test now enters the ending with a failing store, renders its warning,
restores storage, presses Escape, and decodes a successfully saved completed
journey. Resolution: conditional status text and Escape/Start retry at victory.
No engine workaround or framework improvement is needed. Status: resolved with
regression coverage; real-browser final-write rejection is still a separate
full-route verification item.

## Authored text ownership and portable UI (working facility)

Task: replace debug text with readable authored labels while bounding allocations
and preserving cleanup. Context: base c46f228c, Intel macOS, Zig 0.15.2, native
Debug/ReleaseFast and browser ReleaseSmall. Public APIs: AssetCollection.font,
Font.layoutText, TextLayout.draw/deinit and Font.drawText; implementation in
src/typography.zig and Game.init/deinit in src/game.zig. Expected/observed: fonts
and static layouts prepare once, layouts release before their borrowed font,
partial initialization releases prior allocations, and drawing needs no new
allocation. Exhaustive allocation-failure walking and a drawing check with a
failing allocator pass. Static copy is checked against logical width budgets.

The game keeps a bounded static copy catalog and explicit heading/body styles;
numeric HUD text uses direct allocation-free drawing. This is game-owned UI
organization, not evidence for a new engine UI/caching subsystem. Browser
readback/menu/reload checks pass in Chromium, Firefox and Safari 18.6. The Safari
check uses independent and game renderer probes, preserving the existing one-
channel-unit tolerance and exact red-pixel contract. Screenshots/JSON live in the
game's zig-out/evidence directory. Classification: documented facilities working,
severity none, no workaround or engine API change. Full-game profiling remains
separate from this zero-allocation text-draw check.
