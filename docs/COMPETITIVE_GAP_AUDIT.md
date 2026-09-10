# V1 audit and execution checklist

## Baseline and evidence

The starting product is `e39be5a` (`feat: complete alpha release candidate`). The only initial
worktree addition was the supplied `PX240C_V1_PRODUCT_PASS.md`. No product code was changed before
running the complete gate. Its first invocation stopped at formatting of that new brief; formatting
the brief and rerunning `./scripts/check.sh` passed: Prettier, ESLint, all TypeScript projects,
42 Vitest tests, production asset/build generation, one complete Firefox E2E, Rust formatting,
Clippy with warnings denied, 45 Rust tests, native build, and release Wasm build.

The product brief is the scope contract, including all P0/P1 and named P2 requirements. This audit
does not promote unverified competitor claims into facts. No implementation decision currently
requires a competitor's present price, specification, licensing, or API behavior: the decisions
below follow the requested product contract and inspected PX-240C code. Official sources will be
checked before relying on any such external claim. No competitor code, art, or branding is imported.

Inspected instructions and handoffs: `AGENTS.md`, both product briefs, root README, PROGRESS, LIMITS,
ARCHITECTURE, all three ADRs, HARDWARE, SECURITY, DEBUGGER, CARTRIDGE_FORMAT, PXCL, API, ASSETS,
STUDIO, TUTORIAL, PRODUCT, cartridge README, COPYRIGHT, and root THIRD_PARTY_NOTICES. Package
manifests, Makefile, build/check scripts, lockfiles, runtime, compiler/linker, CLI/LSP, Studio,
debugger and E2E are stronger evidence than aspirational prose. This is a Vite application, not
a Next.js application; the generic Next.js AGENTS block has no installed Next.js guide to apply.

## Measured alpha

`tests/fixtures/alpha/` preserves original complete cartridges, an actual first-install IndexedDB
project snapshot, and 240-frame production-Worker recordings per game. Each frame records exact
input, work, draw/audio/save commands, SHA-256 of the indexed pixels sent to WebGL, and SHA-256 of
the Worker snapshot. The final snapshot is retained in full. These are observations of alpha,
not expected values synthesized from a proposed V1 implementation. Do not regenerate them from V1.

| Game                          | Complete `.pxc` bytes | Visual bytes | Short-path work peak | Draw-command peak | Audio-command peak |
| ----------------------------- | --------------------: | -----------: | -------------------: | ----------------: | -----------------: |
| Cinder Circuit                |                42,121 |        9,766 |               10,477 |                90 |                  1 |
| Ashvault                      |                40,532 |          288 |               19,140 |               120 |                  3 |
| Raster Rush 99 (four players) |                37,311 |          160 |               31,722 |               470 |                  1 |

Paths: Cinder starts, runs right, jumps and encounters hazards; Ashvault starts and takes discrete
cardinal turns; Raster Rush starts four players, accelerates, boosts each port and steers in opposite
directions. All use seed `0x240c1999` and initially empty save data. The older PROGRESS work figures
3,342/12,031/31,682 describe representative active frames, **not whole-path peaks**. Keep this
distinction in the new profiler and handoff. These short paths are regression boundaries, not proof
of every level or ending.

The production synth's post-frame active-voice peaks for these paths are 4/5/5. The canonical
48 kHz stereo float32 PCM hashes are frozen in `audio.json`; all 720 recorded browser framebuffer
hashes also match the unchanged production rasterizer when driven by their recorded commands.

Baseline production assets: main JS 121,103 bytes; Worker JS 18,722; CSS 12,372; Wasm 1,165,346.
Exact artifact and bundle hashes are in `metrics.json` and `bundles.json`. Packed generated JS
figures previously recorded by alpha are 13,896/18,832/16,546 bytes; those must be remeasured through
the V1 section accountant before use in the final comparison.

The reproducible browser measurement includes editing a real source comment, save/back, run,
compilation, Worker initialization and the first rendered frame, measured by Playwright wall clock.
Original single-file Cinder: cold 338.9 ms, ten warm median 297.8 ms. The same project split into
two modules in an isolated browser profile: cold 579.5 ms, ten warm median **282.1 ms**. Raw samples
are retained in `metrics.json` and `latency.json`. This includes automation and UI overhead; it is
not a compiler-only benchmark. The split never changes repository/game sources. The recorder
refuses execution after alpha implementation changes and refuses to overwrite archived artifacts.

Firefox 155.0 (repository Playwright build 1543) recorded the goldens. The CLI skill's separate
Firefox installation was also used for interactive inspection, not claimed as the release browser.
The shell and all three running games were visually inspected at integer-scaled resolution;
screenshots are local under `output/playwright/alpha-*.png`. UI controls overlap the lower screen
in alpha screenshots: capture must read the indexed output directly and exclude host controls.
Chromium, PWA installation UI, and Safari have not been validated at this checkpoint. Safari is
outside the available Linux verification contract.

## Architectural decisions

1. Keep the Rust compiler and existing deterministic scheduler, indexed rasterizer, synth, asset
   codecs, repository and replay journal. Extract the Worker dispatcher into a host-independent
   production core first. Move graphics/audio ownership into that core before exposing bus access.
   The page becomes an input/presentation/storage adapter. Headless and standalone must drive this
   same core; remove the exporter's hand-maintained runtime once parity is demonstrated.
2. Bus access must reach actual typed-array/device storage, not a periodically copied debugger
   facade. Use a fixed byte-addressed space with explicitly reserved holes, little-endian words,
   permissions and transactional range validation. Freeze numerical addresses only alongside
   register tests and the full reference. Keep front/back address identity stable through frame
   completion. Preserve the existing high-level draw/raster ordering and work charges.
3. Replace textual linked-name rewriting with project symbol identities and original-file spans.
   Keep legacy flat/single-file behavior as a compatibility path. Resolve visibility, imports,
   dependencies and references once for native/Wasm/editor/LSP services. Real debug suspension
   belongs in compiler-generated continuations, not host JS evaluation or frame-trace navigation.
4. Preserve canonical source and asset names. Add versioned envelopes/migrations around existing
   import/export/persistence paths. A tiny cart may compile on load, but its measured size includes
   everything per-cartridge. No source-stripping or hidden per-cart dependencies for class badges.
5. Reuse each editor's data model and the repository's revision checks/recovery mechanism. Improve
   transactional operations and exact accounting before expanding the UI. Keep the console font,
   palette, 240×144 presentation and all three original games unchanged unless a demonstrated
   regression requires a specific compatibility correction.

Known gaps directly verified in the initial alpha implementation: Worker-only map copies versus host visual assets;
host-owned graphics/audio; duplicate standalone runtime; global uniqueness in project linking;
same-document lexical LSP navigation; frame-boundary debugger and captured-probe stepping; one
map tileset and one raster row in editors; unsupported custom-font decoding; no headless CLI
execution (`run --no-open` exports HTML); keyboard mappings for two ports only; Firefox-only E2E.
Input edges are sampled every display frame even in 30 Hz carts. Checkpoint 2f explicitly reproduces
an odd-frame press being visible to drawing but absent from the next update's `btnp`, including
restore/forward behavior. The bus preserves that timing; no control change is inferred from browser retries.

Checkpoints 2a–2f now place actual graphics/audio, visual allocations, input registers and a partial byte bus inside the shared Worker
core, with native execution against the frozen alpha traces. They remove the host-owned device
copies above but do not complete Hardware Revision 1, standalone consolidation or source suspension.
See PROGRESS for exact verification and the remaining device mappings; the milestone checklist
below stays open until the complete outcomes pass.

## Required implementation checklist

Checkboxes represent verified outcomes, not files merely created. The complete verification and
stopping contracts in the brief remain authoritative in addition to this checklist.

### 1. Audit

- [x] Read instructions/handoffs; inspect status, manifests, tasks and implementation; pass alpha gate before implementation.
- [x] Preserve packed alpha games/projects and actual Worker/input/frame/state/audio traces; inspect running games and shell.
- [x] Record exact packed/visual/work/command/bundle metrics and repeatable single-/multi-module edit-run samples.
- [x] Freeze production PCM/voice measurements and verify recorded pixels through the shared rasterizer.
- [x] Record architecture decisions, evidence gaps, non-goals and full remaining checklist.

### 2. Hardware Revision 1

- [ ] Fixed layout/reference for RAM, front/back/display, 128 KiB visual store and allocation/descriptors, map/tile/sprite/font, palette/transparency/camera/clip/raster, four input ports/edges, eight voices/tracker, time/RNG/work/faults, 8 KiB save/commit, ROM/metadata and reserved space.
- [ ] Document/reset/test byte order, alignment, permissions, no mirrors, bounds, values, visibility timing and operation costs for every region/register.
- [ ] Public PXCL byte/word read/write, overlap-safe copy/fill; high-/low-level mixed graphics/map/audio/input/save/raster use one backing state and deterministic faults/work.
- [ ] Paused memory/register editor with labels, hex/decimal, changes, watchpoints and manual links; bounded per-scanline effects.

### 3. Conformance and headless execution

- [ ] No-browser conformance for every region/register plus reset/aliasing/bounds/endianness/framebuffer/raster/input/audio/tasks/RNG/save/work/faults.
- [x] One production-core headless CLI accepts cartridge, seed, frame/update count, scripted input and save; emits frame/state/audio or PCM hashes, peaks and faults.
- [ ] Browser/headless golden parity in both browsers; original three game paths preserve output, controls, audio and saves.
- [ ] Raw pre-V1 cartridge/project/replay/save compatibility fixtures migrate without replacing originals; public source-visible PXCL diagnostic/service cart.

### 4. PXCL projects and external tools

- [x] Namespaced symbols, public/private, aliases/qualified names, deterministic initialization, cycles/collisions; legacy flat and single-file carts valid.
- [ ] Shared native/Wasm/Studio/formatter/explorer/LSP semantic model, original-file locations, dependency-based incremental invalidation.
- [ ] Semantic cross-file definition/reference/rename/completion/hover/signature/diagnostics/document and workspace symbols; comment/format-preserving rename.
- [ ] Coherent new/fmt/check/build/test/watch/run/pack/info/export; watch refresh/restart and diagnostics, conflict-safe opt-in browser folders with IDB/file fallbacks.
- [x] Pure assertions, expected compile failure, scripted frames, framebuffer hashes, seeds, save fixtures and source-located test failures; test-only content excluded from release.
- [ ] Repeat baseline benchmark after changes, target warm median below 300 ms without material regression; deterministic restart, no fake state-preserving reload.

### 5. Source debugger and replay

- [ ] Actual statement suspension/continue/restart/step in/over/out in nested functions, loops, module calls, callbacks, tasks/yields and supported recursion.
- [ ] Original-module source maps and typed locals/globals/collections/stacks/current location/task state; release instrumentation stripping.
- [ ] Restricted PXCL conditions and read-only typed watches, no JS eval; memory watchpoints; persisted/remapped breakpoints; generated code and IR views.
- [ ] Defined Worker/render/audio/input/timer pause semantics, no host-time state advance or hanging notes; rewind then forward along recorded input; edits/faults covered.

### 6. Creation tools

- [ ] Maps: multiple atlases/tilesets/layers, visibility/order/flags/transforms, region select/fill/stamp/move/copy/paste/resize, exact storage and old-map migration.
- [ ] Raster: complete 144-row table, ranges/keyframes/copy/paste/fill/numeric interpolation/enable, live preview and work cost for actual hardware registers.
- [ ] Fonts: variable bitmap glyphs/map/baseline/advance/missing glyph, preview/select/transforms, deterministic decoder/editor/interchange, independent unchanged system font.
- [ ] Deterministic PNG nearest/ordered-dither conversion preview and explicit transparency; sprite/map/label/font/audio interchange and useful exports.
- [ ] All editors: consistent keyboard/selection/undo/redo/dirty/autosave/recovery/conflict UX; exact before/after object/visual/cartridge accounting and transactional overflow rollback.

### 7. Audio and capture

- [ ] Reusable instruments/custom waves/envelopes/effects, tracker pattern order/flow, per-channel audition/mute/solo, scope/spectrum or voice-state and steal/work inspection.
- [ ] Production synth and memory registers/tracker/debug/replay/WAV use one timing model; canonical PCM hash plus audio-command golden.
- [ ] Native/integer-scale PNG, deterministic 30 fps GIF sampling alternate frames with memory/duration limits/progress, frame-exact `.pxrec` round-trip, offline SFX/song WAV; optional synchronized replay audio evaluated.
- [ ] Parse exported PNG/GIF/WAV/replay and compare expected frames/samples; visually inspect captures outside host overlays.

### 8. Cartridge identity and local distribution

- [ ] Original PX-240C physical cart/label PNG with validated ancillary canonical `.pxc` bytes, captured label and title/author/year/players/controls; source-visible raw/PNG round-trip and corruption tests.
- [ ] Local diegetic shelf: bundled/imported labels/metadata/favorites/recents/class/players/save; launch/source/duplicate/rename/export/remove with confirmation/recovery; offline persistence.
- [ ] Extend single offline HTML, itch-ready ZIP/index, embed; metadata/controls/fullscreen/pause/reset/source inspection and isolated saves; no external dependencies.
- [ ] Tiny fragment-only sharing with browser-tested conservative cap and pre-copy meter, clean oversize rejection, no query/upload/request; normal files remain primary.

### 9. Honest size classes and dogfood

- [ ] Complete canonical 4/16/64/256 KiB classification, deterministic packing, source preservation; optimize format if required without weakened sandbox or misleading exclusions.
- [ ] Persistent size/work meter and reconciled CLI/explorer sections: source/generated/visual/maps/font/audio/meta/overhead/compression/save/commands/work/voices/bus; largest symbols/assets and actionable safe suggestions.
- [ ] Distinct source-visible audiovisual demo ≤4,096 bytes, interactive mini ≤16,384, stress/service showcase ≤65,536; labels and real bus/raster/font/audio/capture/debug use.
- [ ] Original three games keep feel/controls/content and ideally ≤64 KiB; report any genuine size crossing rather than mutilating a game.

### 10. Learning and resilience

- [ ] Authoritative searchable in-console/repository manual, help/man/API/hardware/syntax/diagnostic links and code-cursor help at console resolution.
- [ ] Public PXCL interactive 5–10 minute tutorial: pixel/input/animation/sound/save/pack; runnable examples for graphics/sprites/maps/raster/fonts/audio/4P/tasks/saves/modules/tests/bus/profiling.
- [ ] Small blank/arcade/platform/grid/four-player starters, public service cart; no secret host API or Studio rewrite.
- [ ] Version and test project/cart/replay/save migrations with raw originals, transactional recovery, stable save ID/schema/application migration/reset/checksum/truncation/export/import/delete confirmation within 8 KiB.
- [ ] Harden all cart/PNG/map/font/audio/fragment/replay/save/manifest/message boundaries with pre-allocation size/dimension/count/depth/work/path/duplicate checks, property tests, never imported JS execution; CSP/no-network audit and dependency notices/security review.
- [ ] Four-port keyboard/gamepad assignment/remap/conflicts/disconnect/reconnect/local profiles; reduced flashing, muted startup, contrast and larger help outside deterministic/captured output.
- [ ] Chromium and Firefox full workflow matrix, installable PWA and cold offline reload; assert zero normal run/capture/export network requests; accurate platform support statement.
- [ ] README, LANGUAGE, HARDWARE, CARTRIDGE_FORMAT, DEBUGGING, TOOLS, THIRD_PARTY_NOTICES, PROGRESS and LIMITS match executable behavior with no PX-240C license grant.

### 11. Release gate

- [ ] Every first-party cart rebuilt from clean source and packed twice byte-identically, measured and exported as raw/PNG/HTML/ZIP plus applicable captures; compatibility/conformance hashes recorded.
- [ ] Clean-storage full Firefox/Chromium E2E covers every required authoring/debug/tooling/persistence/distribution/offline path; direct native/scaled screenshots/capture inspection.
- [ ] Root check/Make runs every required local formatter/lint/type/unit/integration/browser/native/Wasm/conformance gate with no required skips; no known high-severity dependency/parser issue.
- [ ] Exact before/after metrics, browser versions, artifact hashes, migrations, checkpoint commits and intentional limits documented; all work committed locally, clean tree, nothing pushed/published/deployed.

Non-goals remain exactly those in the brief: no cloud/accounts/telemetry/community/backend, netplay,
foreign-console imports, alternate hardware/palette/shaders/3D/analog, generic engine/registry/plugin
or multi-language platform, native desktop rewrite, wholesale PXCL Studio, game redesign, copied
branding/assets or license grant. A failed check leaves its requirement open; it is not a scope waiver.
