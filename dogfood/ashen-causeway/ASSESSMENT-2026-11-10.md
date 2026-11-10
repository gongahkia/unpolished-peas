# Ashen Causeway integration assessment — 2026-11-10

Ashen Causeway implements a beginning-to-ending action RPG through Peas's public
native/browser GameProtocol workflow. Complete automated routes and reloads pass
in SDL, Chromium, Firefox and real Safari. **The game remains under review:**
its intended 15–30 minute first-success duration is unmeasured, and the expert
route takes only about 110 seconds of simulation. That is a significant pacing
risk; automation does not establish enjoyment, sufficient content or final polish.

[Design and combat contract](DESIGN.md), [launch/verification guide](GUIDE.md),
[canonical friction report](FRICTION.md), [measured workload](PROFILE.md) and
[chronological evidence](PROGRESS.md) separate implemented behavior from proof.
The implementation includes three connected areas, four enemy archetypes, a
phased boss, sabre/spear, stamina/dodge/healing commitments, checkpoints, currency
loss/recovery, upgrades, optional reward/charm, return lift, all requested screens,
original primitive art/audio, authored typography and portable progression saves.

## Division of responsibility

| Peas responsibility exercised | Ordinary game responsibility retained |
| --- | --- |
| Fixed update/draw/lifecycle and host capabilities | Combat windows, cancellation/buffering, stagger policy, AI and phase logic |
| ActionMap physical/pointer/controller inputs | Control choices, committed facing, menu navigation, tutorial progression |
| Canvas rasterization and presentation | Character poses, telegraph geometry, camera clamp, room art, HUD/menu layouts |
| AssetCollection, font layout and audio handles | Static copy catalog, original sounds/score, preparation/release order |
| Native/browser SaveStore and rejected-write preservation | ASH1 version/validation, persisted/transient policy, warnings and retry UI |
| Public replay/headless tests, diagnostics and archive packaging | Complete route pilot, navigation used only by automation, assertions and evidence scripts |

This is a larger integration exercise than a single drawing demo, but it uses
small fixed arrays and a low-resolution Canvas. It does not test streamed worlds,
large asset sets, localization/shaping, physics-heavy scenes, networking, mobile
or general high-resolution throughput. No new scene/ECS/RPG framework was needed.

## Evidence and limits

Combat/progression rules are unchanged since 665bb036; later commits add
verification/profiling tools and reviewed healing/attack preparation poses. Exact reproducible commands are in GUIDE/PROFILE.
The archive report records its actual tree and hashes rather than implying a
later HEAD was tested. Local artifacts live under `zig-out/diagnostics/`:

| Evidence | Observed result | Boundary |
| --- | --- | --- |
| 33 deterministic tests, Debug and optimized runs | Combat boundaries, collision/AI, equipment/progression, saves/failures, repeated cleanup, winning and death/recovery routes pass | Headless controlled input; test fixtures are identified separately |
| `ashen-external/result.json` | Fresh hashed archive fetch; outside-checkout test/package/web/native launch; notices/source retained | Loopback fixture, no published package |
| `ashen-native/result.json` | 6,577-update winning route, ending save and second-process Continue; audio cleanup | Normalized replay through real SDL; CPU captures, no native GPU readback |
| `ashen-browser-route/result.json` | Chrome 157/Firefox 158/Safari 18.6 full route and ending reload; six full RGBA comparisons per browser within tolerance 1 | Actual WebGL 2/Wasm/storage, synthetic replay/time; preview status unchanged |
| Game `zig-out/evidence` browser smokes | Trusted keys/pointer, menus, settings/weapon reload, rejected writes/retry, nonzero finite accepted audio | Does not replace a physical controller/IME/speaker assessment |
| `ashen-motion-review/result.json` | Slowed windup/approach and dodge/shock samples plus full route/reload | Sampled automated visual inspection; not every animation/manual play |
| `ashen-profile/result.json` and final rerun | Three CPU routes, six SDL scene windows, bounded samples, cleanup to zero | One Intel Mac; no GPU-completion/display/JS allocation measurement |

Native ordinary draw medians were 0.209–0.237 ms; phase-two/shock 0.303–0.369 ms,
with presentation-paced frame medians near 16.7 ms. A later one-round rerun is
reported separately. Complete-route drawing/mixing makes zero tracked allocations;
updates make 31 requests totaling 2,530 bytes after init. Peak tracked live bytes
are 1,922,822 and cleanup returns them to zero. PROFILE retains distributions,
workload, a 14.487 ms unexplained native update outlier and allocation scope.
These results do not justify a renderer rewrite or a universal frame-rate claim.

No engine defect was demonstrated or engine fix made by this game. Game defects were fixed with regressions: repeated enemy interruption,
ending-save retry, missing healing poses and hidden upgrade rejection feedback.
The principal remaining workaround is an optional public-replay-to-browser-wire
bridge and test HTTP/RAF shim. It duplicates ABI offsets, expands this input to
about 12 MB and stays out of shipping output. FRICTION records exact context,
reproduction, cost and proposed resolution.

## Priorities supported by this exercise

1. Provide an optional developer replay adapter/encoder for real browser hosts,
   reducing duplicated wire offsets while preserving ordinary shipping bundles.
2. Keep external-consumer and complete-game host checks easy to reproduce; reuse
   the existing diagnostics, strict readbacks and ownership checks. This is an
   ongoing workflow priority, not evidence of another missing game subsystem.
3. Collect wider hardware and first-play evidence before broader support or
   pacing claims. Browser preview status and license/release decisions stay with
   their existing contracts and owner; this exercise changes none of them.

No equivalent raylib, LÖVE or Ebitengine implementation was built or measured.
This demonstrates Peas's combined host/services/replay workflow for this RPG and
machine; it establishes no superiority or comparative productivity ranking.
