# Ashen Causeway final integration review — 2026-11-11

Ashen Causeway is a complete playable developer build with a reviewed beginning-
to-ending route. It integrates deliberate combat, three connected areas, four
enemy archetypes, two weapons, a phased boss, checkpoints, death/currency recovery,
equipment/upgrades, a useful lift, optional reward, all requested screens,
authored typography, original primitive art/audio and portable progression saves.

The intended 15–30 minute first-success duration remains **unverified**. The expert
automated route takes 109.6 seconds of simulation. That is a substantial pacing
risk; neither first-play duration nor enjoyment is established. This review accepts
the bounded implementation and observed workflows, with those limits visible.
It does not convert automation into human play evidence or add time padding.

[Design/actual rules](DESIGN.md), [launch and exact verification commands](GUIDE.md),
[canonical friction](FRICTION.md), [performance/resource observations](PROFILE.md)
and [chronological evidence](PROGRESS.md) provide the concrete reproduction record.
The earlier [November 10 assessment](ASSESSMENT-2026-11-10.md) preserves the working review.

## What Peas handled

| Framework responsibility exercised | Responsibility retained in ordinary game code |
| --- | --- |
| Fixed GameProtocol lifecycle, input snapshots and hosts | Combat timing/cancellation/buffering, facing, AI and boss phases |
| Physical/pointer/gamepad ActionMap input | Control choices, menus and contextual tutorial |
| CPU Canvas and native/browser presentation | Collision/layout, camera policy, silhouettes/poses, telegraphs and HUD |
| AssetCollection, font layouts and audio handles | Static copy catalog, original score/effects and explicit cleanup order |
| SaveStore and failed-write preservation | ASH1 version/checksum, progression/transient policy, warning and retry UI |
| Replay/headless tests, diagnostics and package boundary | Route pilot/test navigation, assertions, host replay bridge and observation tools |

No general RPG, ECS, scene, physics, navigation or rendering subsystem was added.
The game uses small fixed arrays and 480×270 CPU drawing. It demonstrates the
combined portable host/services/replay workflow at that scope, not streamed worlds,
large content sets, localization/shaping, networking, mobile or high-resolution
scalability.

## Proof actually obtained

Production game source is 50511dde. Later changes affect verification and documents.
All 34 game tests pass in Debug and ReleaseFast. Keyboard/mouse and virtual-controller
routes complete and replay in 6,577/6,320 input ticks; both exercise boss phases,
shock, rest, an upgrade, reward and lift. A separate ordinary-input route earns
currency, dies, respawns, defeats reset enemies and recovers the drop. Tests cover
boundary timing, wall occlusion, damage-once, interruption/cancellation, equipment,
save round trips/failures and repeated lifecycles. These are controlled tests.

| Real workflow | Result / retained report under root `zig-out/diagnostics` |
| --- | --- |
| Fresh external archive consumer | `ashen-external/result.json`: real hashed archive fetch, 34 tests, native package/web/120-frame SDL launch, authored sources/notices retained; tree 51f7664c69812efd5bd7729fcb652ac1de655992 |
| Full SDL route and new process | `ashen-native-final/result.json`: 6,577 updates, ending/progression/equipment loaded by a second process, full checkpoint resources and audio cleanup; exact UUID namespace removed |
| Chrome 157 / Firefox 158 / Safari 18.6 | `ashen-browser-route/result.json`: archive-built Wasm full route, actual ending reload and six full 480×270 RGBA comparisons/browser at tolerance 1; strict independent probes retained |
| Explicit browser shutdown | Same report: no protocol failure, zero scheduled frames/game GPU resources, host destroyed and test-origin saves restored in all three browsers |
| Trusted browser input/audio/save recovery | Game `zig-out/evidence/browser-smoke.json`: Chromium/Firefox menus, actual reload, rejected-write preservation/retry, corrupt-slot explicit replacement/reload and finite nonzero accepted audio; Safari trusted menu/settings reload is separately recorded |
| Actual visual review | Native/browser route frames, title/settings/pause/credits/death, actual death/respawn/recovery, isolated archetype studies and slowed windup/dodge/shock samples; limits identified in PROGRESS |
| Documentation/recipes | 43 build steps/36 tests passed, including native/Wasm API, assets, input, fonts, audio and replay recipes; final links checked again at handoff |

Native captures are CPU Canvas output from real SDL callbacks, not native GPU
readbacks. The complete browser replay injects normalized snapshots and synthetic
RAF time through a test-only HTTP shim. Trusted browser input is checked separately.
Neither route automation nor injected input is physical controller/IME validation.
All recorded runtime checks above were completed November 10 in the user's UTC+7
zone; this handoff is dated November 11.

## Review findings and measured limits

Concrete game findings were corrected with regressions: repeated enemy interruption,
ending-save retry, controller movement precision, missing healing/attack preparation
poses, hidden upgrade feedback, stale title text after successful replacement and
misleading/silent rejected-command feedback. Font hierarchy, stable HUD columns,
landmarks and interaction labels were reviewed through actual captures. The inspected routes have no remaining demonstrated correctness finding.

Current full-route counting reports zero draw/mix allocations, 31 update allocation
requests totaling 2,530 bytes after init, peak tracked live bytes 1,879,998 and zero
after cleanup. Counts include logical audio/in-memory saves/headless objects,
not C/SDL/driver/JavaScript/GPU memory. CPU ordinary/shock draw medians are 0.117/
0.276 ms in the final one-round run. SDL draw medians are 0.166/0.317 ms, with frame
medians around 16.7 ms including swapchain pacing. These are one-machine observations.

An ordinary native update reaches 40.598 ms (frame 41.210 ms) at input tick 555,
coinciding with a 40-byte update allocation. Synchronous SaveStore work is a candidate;
per-write and OS-scheduler attribution remain open. PROFILE retains all tails and
historical observations, including an earlier profiling progress-I/O limitation.
Final profile mode suppresses that observer line and rejects failed persistence.
No renderer bottleneck or hard frame guarantee follows from these measurements.

Physical controllers, OS IME, assistive technology, speaker quality, input/display
latency, Apple Silicon, native Linux/Windows interaction, browser performance and
native GPU readback remain unverified. Peas browser preview status is unchanged.
Existing README files and third-party notices are preserved. No license was chosen,
no release was published/deployed, and no branch was pushed.

## Engine friction and next priorities

No engine correctness defect or engine API fix was required by this game. Game
bugs stayed in game commits. Two open observations are supported by evidence:

1. Provide an optional developer replay adapter or canonical Snapshot-to-browser-
   wire encoder. The current game-owned bridge duplicates ABI offsets, expands
   this replay to about 12 MB and stays out of shipping output.
2. Add optional save-duration attribution to developer diagnostics. The retained
   native tail warrants investigation; any coalescing should follow evidence and
   preserve explicit pending-save feedback and write guarantees.
3. Keep complete-game archive/host checks reproducible and collect first-play and
   wider hardware evidence before broader pacing/support claims. These are workflow
   improvements, not evidence for another game subsystem.

No equivalent raylib, LÖVE or Ebitengine implementation was built or timed. This
exercise establishes neither superiority nor comparative productivity/scalability.


## Focused local commits

Implementation and verification history through 50b853fe is retained below; the
handoff documentation commit follows it. Nothing was pushed.

```text
617839ed Define Ashen Causeway scope and acceptance gates
aea32d01 Implement deterministic RPG combat windows and boundary tests
61eff793 Add bounded RPG world collision encounters and checkpoint progression
336fd67b Wire Ashen Causeway to public native and browser GameProtocol hosts
c09375b1 Record native and browser smoke evidence for the RPG prototype
54829e4e Add versioned RPG progression saves and meaningful lantern equipment
45104829 Add RPG continue new-game settings upgrade and ending menu flows
5fea8558 Verify RPG browser save reload rejection and retry workflows
b57d06b1 Implement Censer projectiles and alternating Warden bell shocks
855a830b Add combat silhouettes original audio and contextual action feedback
c767c692 Verify hazard fairness audio playback and live browser encounter cues
a69e14b4 Improve controller movement precision and ending save recovery
a77bb9f2 Verify complete RPG input routes replay and currency recovery
c46f228c Document complete route evidence and remaining RPG acceptance gates
fd26d34c Add prepared authored typography and clear RPG navigation landmarks
665bb036 Verify authored UI and save reload through real Safari and browser captures
49209ed4 Verify Ashen Causeway through a fresh external archive consumer
372524c7 Add optional native journey replay and browser reference exporters
471a17dd Verify complete archive-built RPG routes and reloads in three browsers
1479c041 Profile RPG callback allocations and real SDL combat presentation
b0960b77 Capture slowed Warden combat sequences for presentation review
54de0808 Assess RPG integration evidence and retain unresolved pacing gates
022976b0 Make healing commitment and attack preparation visibly distinct
b26b9651 Explain upgrade prerequisites and preserve pause action feedback
80ff9134 Retain real death recovery frames and isolated action studies
248b0b49 Clear stale load warnings after a successful save replacement
50511dde Report rejected commands and reserve bell cues for successful interaction
50b853fe Verify browser shutdown and retain corrected final resource measurements
```
