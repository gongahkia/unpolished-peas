# Neon Siege polish plan — 2026-11-12

Baseline: clean 76a82556; Zig 0.15.2/Intel macOS. Debug test/web/package passes
20 steps/10 tests. Chromium startup initially fails because the package names
its Wasm differently from the common bootstrap. After that packaging correction,
trusted keyboard movement/fire/boost/restart and strict readbacks pass.
Captures: root zig-out/diagnostics/two-games-baseline/neon-siege-*.

Intended feel: snappy, readable arena survival. Movement aims by default; explicit
keyboard/controller aim supports shooting while repositioning. X/East is a held
sprint, not an invulnerable dash. No stamina system. Show the whole bounded arena,
telegraph safe spawns, and retain a brisk endless wave loop with escalating,
bounded threat. Keep art silhouettes and low-resolution pixel composition.

Reproduced/source findings: web startup fails; moving camera conceals threats;
boost copy disagrees with held behavior; damage immunity has no readable cue;
no onboarding/pause/best display; initial blocked music has no update retry;
game deinit does not release audio; saved-write failure is silently ignored.
Aiming/cadence and spawn changes are design improvements, not engine defects.

Bounded work: separate drawing from fixed-update rules first with existing trace/
pixel assertions unchanged. Then add clear title/play/pause/death states, consistent
controls, direction/shot/damage/pickup/wave feedback, fair telegraphed spawns and
stable HUD. Use existing authored font deliberately with prepared static text.
Keep reusable resources across restarts and release them at lifecycle end.
Preserve valid six-byte settings/best records and expose pending save/retry.

Acceptance: ordinary keyboard and virtual-controller input starts, moves, aims,
fires, sprints, clears at least three waves, takes damage, earns a pickup, dies
and restarts. Pausing consumes no simulation and leaks no queued actions. Browser
music recovers after a trusted gesture; audio preference and earned best survive
actual reloads. Draws do not advance state; repeated initialization/restart/cleanup
and allocation-failure checks pass. Full renderer references and shutdown pass in
available Chromium/Firefox/real Safari; missing prerequisites are unverified.

Review typography, surfaces, animation, silhouettes and performance in full skill
mode, including ~10% motion captures. Check native/Debug/optimized/web builds,
archive consumers/notices, real process reload and bounded serial profiling.
Non-goals: campaign/end state, inventory, networking, ECS, scene/UI framework,
engine rendering changes, physical-device or human-playtest claims.
