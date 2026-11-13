# Lantern Leap polish plan — 2026-11-12

Baseline: clean 76a82556; Zig 0.15.2/Intel macOS. Debug test/web/package passes
20 steps/6 tests. The same browser Wasm-name mismatch prevents startup until
packaging is corrected. Subsequent trusted Chromium movement/jump/restart and
readback captures are in root zig-out/diagnostics/two-games-baseline/lantern-leap-*.

Intended feel: responsive, compact authored platforming. Preserve direct stopping
and useful air control; deliberately bound coyote time and one-shot jump buffering.
Allow shorter jumps on release if route review supports it. Show landing terrain,
hazards and checkpoint identity clearly; six glows and the beacon form one small
traversal, not a campaign. Geometry changes require a specific traversal reason.

Source/capture findings: Enter during death currently clears collected/checkpoint
state despite documented immediate respawn; no jump buffering; no horizontal
bounds; half-resolution world composition loses sprite detail and the footer
covers floor/hazard pixels; no pause/help/audio control; blocked music is not
retried; loaded audio is not released; checkpoint writes save only aggregate
records, not checkpoint/current-run progress, and failures are silent.

Bounded work: extract drawing without behavior changes, then separate checkpoint
respawn from explicit full restart. Add title/play/pause/death/completion/replay
flows, clear jump/collect/checkpoint/death feedback, readable authored text and
world/HUD separation. Prepare static text, retain resources across run restarts
and release partial/full initialization correctly. Version new current-run/audio
persistence while reading existing valid three-byte records; preserve good data
on rejection and show truthful pending-save feedback/retry.

Acceptance: ordinary keyboard and virtual-controller routes collect all six
glows, activate the checkpoint, die/respawn preserving chosen progress, explicitly
restart, finish and replay. Verify grounded/coyote/buffer limits, underside/edge/
hazard collision, no held-input double jump, and clearing stale actions across
pause/death/restart. Every glow must be reachable without state editing. Actual
process/browser reload restores documented records/current-run progress. Pausing
freezes simulation; draws never advance it. Exercise repeated lifecycles and
allocation failures. Browser autoplay recovers after trusted input; strict probes,
reference readbacks and shutdown pass in all available target browsers.

Full skill review covers typography, surfaces, motion (~10%), icons/silhouettes
and performance. Run Debug/optimized/native/web, archive/notices and bounded serial
profiling checks. Non-goals: more levels, a tilemap/physics/UI framework, inventory,
networking, engine features or claims about untested physical input/hardware.
