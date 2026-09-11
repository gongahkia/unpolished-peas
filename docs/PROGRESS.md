# Implementation progress

This log records verified milestones and remaining risks. The product brief is the stopping contract.

## Plan

1. Establish pinned workspaces, trust-boundary ADRs, and strict native/browser quality gates.
2. Implement PXCL spans, indentation-aware lexer/parser, formatter, fixtures, and stable diagnostics.
3. Add resolution, type checking, typed assets, typed IR, tasks, and cross-mode code generation.
4. Build deterministic runtime, worker sandbox, indexed graphics, input, audio, and replay primitives.
5. Implement project persistence, canonical `.pxc`, CLI/watch/LSP, shell, and integrated editors.
6. Add debugger/profiler/time travel and use pack-in cartridges to calibrate public facilities.
7. Finish PWA/export, documentation, accessibility and visual validation, then run the full audit.

These are execution groups rather than substitutes for the brief's thirteen milestone outcomes.
Each group may produce several coherent commits, and integration occurs throughout.

## 2026-09-07 — Milestone 1: foundation

- Inspected the initially empty Git repository and complete authoritative product brief.
- Verified Node.js 22.22.2, pnpm 10.32.1, Rust/Cargo 1.98.0, and Git 2.55.0.
- Installed user-local Rust 1.98 components for rustfmt, Clippy, and WebAssembly compilation.
- Added the Cargo/pnpm workspace, initial static studio shell, frozen experimental constants, ADRs,
  proprietary notice, and quality-gate commands.
- Verification: `make setup` and `./scripts/check.sh`; TypeScript format/lint/type tests, Vitest,
  browser production build, Rust formatting/Clippy/tests/native build, and release WASM build pass.

## 2026-09-07 — Milestone 2: PXCL syntax front end

- Added byte-accurate source spans, line indexing, serializable stable diagnostics, and an
  ASCII-only indentation lexer with comments, assets, duration literals, CRLF handling, and recovery.
- Added a recovery parser and serializable AST for modules, records, enums, typed state/functions,
  deterministic tasks, callbacks, control flow, exhaustive-match syntax, types, and expressions.
- Added an idempotent two-space formatter, `px240c check`, `px240c fmt`, file-backed positive and
  negative fixtures, exact diagnostic-span assertions, and 512 bounded generated parser inputs.
- Exposed tokens, AST, and diagnostics as JSON through the WebAssembly boundary.
- Verification: `./scripts/check.sh`; 17 Rust tests, one Vitest test, strict Rust/TypeScript lint and
  type checks, native/browser builds, and release WASM compilation pass.

## 2026-09-07 — Milestone 3: resolution, types, assets, and typed IR

- Added deterministic global/local symbol tables, declaration collection, lexical scopes, duplicate
  definition spans, named type resolution, non-capturing function types, and contextual literals.
- Added bounded array/list and `Option` typing, records with trailing defaults, enum constructors and
  exhaustive matches, mutability and return-path checks, callback contracts, and task-only suspension.
- Added a typed asset catalog with precise missing/wrong-kind errors and public graphics/audio handle
  types, plus compile-time constant evaluation and module assertions.
- Lowered valid modules to serializable typed IR shared by future debug/release generation; CLI
  `check` and browser analysis now use semantic analysis rather than syntax alone.
- Added positive/negative type fixtures covering independent errors and fully typed IR invariants.
- Verification: `./scripts/check.sh`; 22 Rust tests, one Vitest test, strict Rust/TypeScript lint and
  type checks, native/browser builds, and release WASM compilation pass.

## 2026-09-07 — Milestone 4: code generation, deterministic runtime, and worker sandbox

- Added release/debug ES-module generation from the same typed IR, standard source-map v3 output,
  direct span relationships, safe-integer checks, work instrumentation, and CLI/browser bindings.
- Lowered tasks, including nested branches, loops, fixed iteration, matches, waits, and launches, to
  explicit serializable program-counter state with locals, iterators, and temporaries.
- Added seeded xorshift32 RNG, frame-derived time, 30/60 Hz scheduling, source-attributed frame
  budgets, structured snapshots/restores, four-port input frames, and validated runtime faults.
- Added the disposable module-worker protocol, blob-only loading, ambient capability lockdown,
  cloned command output, host response deadlines, and compiler-produced browser smoke fixtures.
- Proved representative debug/release semantic equivalence by executing both outputs under Node.
- Playwright/Firefox production-bundle checks passed normal execution, denied-capability audit, and
  a source-mapped runaway loop; visual inspection passed exact 2x and 3x viewports without clipping.
- Verification: `./scripts/check.sh`; 28 Rust tests and seven Vitest tests, formatting, ESLint,
  strict Clippy and TypeScript checks, native/browser production builds, and release WASM compilation
  pass. Playwright checks used the generated production fixtures in Firefox 155.

## 2026-09-07 — Milestone 5: indexed hardware, input, and synthesizer

- Added the fixed original 32-colour palette, persistent double-buffered indexed storage, integer
  primitive rasterization, logical remapping, camera/clip state, and a WebGL2 palette resolver.
- Added transparent variable sprites, animation frames, 8x8 layered tile maps and flags,
  nearest-neighbour integer transforms, bounded map queries, ordered dithering, and an original 5x7
  built-in bitmap font with shared visual-capacity enforcement.
- Added scanline scroll/palette display state, phase-aware console calls, facility-specific work
  costs, the 4,096-command limit, and exact browser protocol validation.
- Added keyboard, pointer/touch, and standard-gamepad translation into four complete controller
  ports, plus statically constructible controller and button values in PXCL.
- Added five oscillator sources, envelopes, pitch slide/vibrato, pan, deterministic eight-voice
  allocation, an eight-channel pattern/order tracker, snapshot restore, and a user-gesture Web Audio
  queue. Imported sample data is not representable.
- Playwright/Firefox checks rendered the compiler-produced graphics fixture through WebGL2 at exact
  2x and 3x scales, preserved capability/runaway behavior, and started Web Audio after a button click.
- Verification: `./scripts/check.sh`; 29 Rust tests and 25 Vitest tests, formatting, ESLint, strict
  Clippy and TypeScript checks, native/browser production builds, and release WASM compilation pass.
  Browser adapter checks used Firefox 155 and compiler-produced PXCL fixtures.

## 2026-09-07 — Milestone 6: projects, cartridges, persistence, CLI, and LSP

- Added strict `cart.toml` parsing, dependency-ordered dotted module imports, project-wide typed
  compilation, and explicit errors for missing/cyclic modules, dependency callbacks, and name
  collisions.
- Added the bounded deterministic `.pxc` revision-1 container with canonical paths/JSON/RLE,
  original normalized source, release JavaScript/source map, assets/presentation files, SHA-256
  inventory, post-pack decode, corruption checks, and 256 KiB enforcement.
- Added `new`, project-aware `check`/`build`, `pack`, content-based `watch`, project/cartridge `info`,
  and a protocol-tested stdio LSP with diagnostics, completion, hover, definitions, references, and
  rename.
- Added browser project/settings persistence, ten pre-save recovery revisions, immutable-ID 8 KiB
  save capabilities, worker save calls, deterministic write batches, and snapshot inclusion.
- Playwright/Firefox exercised real IndexedDB recovery and cross-cartridge save isolation, plus a
  compiler-produced worker fixture that loaded and updated prior save state. The production page
  reported no console errors and was visually inspected at 3x.
- Verification: strict Rust formatting/Clippy and 36 Rust tests pass; Prettier, ESLint, strict
  TypeScript checking, 30 Vitest tests, runtime build, and production Studio build pass. Full-suite
  verification is recorded by the milestone commit.

## 2026-09-07 — Milestone 7: boot monitor and integrated execution

- Added a generated WebAssembly browser bridge to the authoritative Rust compiler, project linker,
  formatter, packer, and decoder; the pinned binding tool is part of the reproducible setup path.
- Replaced the static boot mockup with a keyboard-operable 240x144 monitor shell backed by the real
  IndexedDB repository. Project creation/loading, explicit saves, bounded recovery selection,
  directory/info output, editing, running, and `.pxc` download are functional.
- Added a compact source editor with live compiler diagnostics, canonical formatting, persistent
  save, and direct run controls. The default project is valid PXCL/1 and visibly responds to input.
- Integrated project execution with the dedicated worker, indexed WebGL output, four-port browser
  input, frame/work meters, and per-cartridge save write flushing. Shift+Escape stops and disposes
  the worker/input adapters before returning to the shell.
- Playwright/Firefox completed create -> edit -> diagnose -> save -> compile -> run -> stop -> reload
  against the production build. Reload recovered revision 2 from IndexedDB; no console errors were
  reported. Shell, editor, and running cartridge were visually inspected at exact 3x scale.

## 2026-09-07 — Milestone 8: integrated creation tools and asset pipeline

- Added source-visible revision-1 JSON codecs for variable sprites/animations, 8x8 tile sets and
  flags, layered maps, oscillator patches, tracker songs, and default palette/raster display state.
  Runtime loading validates references and hardware bounds before cartridge execution.
- Added functional in-display sprite, map, palette/raster, sound, music, and project-settings tools.
  The graphics tools provide bounded painting, navigation, selection/transforms, onion skinning,
  undo/redo, and capacity feedback; audio tools provide patch/pattern editing and gesture-gated
  previews.
- Expanded the editor with PXCL highlighting, completion, same-file definition lookup, and explicit
  external-revision reload. Added searchable built-in manual and compiler-explorer views for every
  exposed pipeline stage and size/work accounting.
- Connected saved visual/audio assets to the production player. Project display defaults now affect
  indexed drawing and scanout, count toward the shared visual capacity, and remain overridable by
  public PXCL palette/raster calls.
- Playwright/Firefox exercised each editor, persistent saves, deterministic `.pxc` download, asset
  loading, running audio enablement, stop/reload, manual search, and compiler-explorer switching.
  The initial sound/music file-revision integration fault was reproduced and regression-tested;
  the corrected run reported no console errors. Sprite, map, and palette tools were visually
  inspected at exact 3x scale.
- Verification: `./scripts/check.sh`; Prettier, ESLint, strict TypeScript, 33 Vitest tests, production
  build, Rust formatting/Clippy, 37 Rust tests, native workspace build, and release WebAssembly
  build pass.

## 2026-09-07 — Milestone 9: debugger, profiler, and deterministic rewind

- Extended debug generation with source probes that capture ordinary routine parameters/locals,
  task locals/program counters, and call stacks while preserving release/debug IR and semantic
  equivalence. Worker traces are protocol-validated and bounded to 4,096 events per frame.
- Added real pause/resume and frame advance, conditional source-line breakpoints, safe watches,
  frame-trace step into/over/out, restart, direct timeline rewind, and divergence reporting in one
  keyboard-operable 240x144 debugger surface.
- Added per-line cumulative synthetic-work profiling plus globals, tasks, stack, framebuffer,
  visual-assets/capacity, packed-size, palette/raster, synthesizer-voice, and tracker inspection.
- Added a bounded replay journal that records every input frame and deterministic output/state
  fingerprint. Composite snapshots cover worker/RNG/task/save-copy state, persistent/resolved
  indexed graphics, and synthesizer/tracker state before frame 0 and every 30 frames.
- Playwright/Firefox exercised a task/function cartridge through frame advance, routine and task
  local capture, call-stack navigation, conditional breakpoint hits, watches, step in/over/out,
  profile/memory/audio views, rewind, restart, and branch execution. The absent-display `null`
  manifest boundary found with a fresh project was corrected and regression-tested. The production
  console reported no browser errors and the debugger was visually inspected at exact 3x scale.
- Verification: `./scripts/check.sh`; Prettier, ESLint, strict TypeScript, 37 Vitest tests, production
  build, Rust formatting/Clippy, 37 Rust tests, native workspace build, and release WebAssembly
  build pass.

## 2026-09-07 — Distribution workflow

- Added bounded `.pxc` project reconstruction and wired explicit cartridge import and source/
  metadata inspection through the shared Rust/Wasm boundary.
- Added one deterministic offline HTML exporter shared by the Studio and native CLI. The embedded
  player runs verified compiled output, exposes every original PXCL module, preserves indexed
  graphics/input/save/audio facilities, and performs no CDN or backend requests.
- Added `px240c export html` and `px240c run` with a headless `--no-open` verification path. Studio
  `pack`, `import`, and `export` downloads were exercised end to end.
- Added a relative-path web app manifest, original maskable icon, and build-generated precache
  inventory. Playwright/Firefox proved a production reload completes with the network context
  disabled after initial installation; standalone worker execution and source inspection reported
  no console errors.
- Narrow verification passed: exporter unit tests, CLI export/run integration, Rust formatting and
  Clippy, ESLint, strict TypeScript checking, production Wasm/Studio build, and browser exercises.

## 2026-09-07 — Milestones 10-12: bundled cartridges and frozen limits

- Added Cinder Circuit, a camera-scrolling four-circuit tile platformer with responsive pixel
  collision, animated movement, task-driven victory feedback, hazards, lives, music, and SFX. Its
  256x18 course remains efficient through camera/clip tile culling in Studio and standalone players.
- Added Ashvault, a turn-based deterministic procedural roguelike with fog of war, records, enums,
  fixed-capacity collections, pursuing enemies, relic/exit objectives, defeat, and isolated saved
  depth progress. Generation now clears a sparse objective spine so every revision-1 seed keeps all
  five relics and the exit reachable while retaining randomized side chambers.
- Added Raster Rush 99, a scanline road-projection racer with steering, boost, off-road slowdown,
  obstacle penalties, timeout/finish states, tracker music, and simultaneous two-, three-, and
  four-player split-screen paths using all controller ports.
- Added original indexed sprite/tile/map art, synth patches, tracker orders, display files,
  labels/thumbnails, deterministic asset generation, build-time Studio packing, first-run local
  installation, public-decoder tests, and CLI compilation/packing tests for all three games.
- Froze the 50,000-unit frame ceiling after production-Studio measurements: Cinder Circuit 3,342,
  Ashvault 12,031, Raster Rush one-player 28,034, and four-player 31,682 representative units. Packed
  cartridges are 37,311-42,121 bytes and visual use is 160-9,766 bytes.
- Playwright/Firefox ran all games through the Studio worker and standalone exporter, exercised the
  four-player view, and visually inspected every title/gameplay surface with clean consoles.

## 2026-09-07 — Milestone 13: release-candidate integration and polish

- Added serialized, revision-checked editor autosave with a 750 ms debounce, bounded recovery, and
  external-change refusal/reload behavior; Firefox verified persistence through a real page reload.
- Added public pointer/touch coordinates and button-edge queries to PXCL, matched standalone input,
  completed standalone synth waveforms/pitch effects, and aligned its facility work accounting and
  raster phase restrictions with the Studio runtime.
- Expanded the Studio tracker from a hard-coded pattern to named pattern creation, editable order
  lists, full-order preview/looping, patch-reference preservation, and bounded undo/redo.
- Added a deterministic TrueType build of the original runtime glyph matrix and applied it throughout
  the shell and integrated tools; the file is included in the offline PWA inventory.
- Added a static diagnostic that confines raster callbacks to palette remapping and raster scrolling,
  after the standalone path exposed an invalid cartridge draw call during scanout.
- Completed runtime semantics for typed options and fixed collections: `some`/`is_some`/`unwrap_or`
  preserve element types, collection/text indexes are checked with source-mapped faults, and
  allocations/capacity writes receive deterministic work charges. Dynamic ranges are charged before
  bounded materialization so an extreme range cannot allocate ahead of the frame budget.
- Calibrated Cinder Circuit as four 2,048-pixel relay runs at 30 updates per second, retaining a
  3,342-unit active-update frame while establishing about 4 1/2 minutes of uninterrupted traversal.
- Added a pinned Playwright/Firefox end-to-end suite to the repository gate. It boots the production
  PWA, runs all three bundled games (including Raster Rush four-player), exercises create/edit/
  autosave/run/debug and every integrated creation tool, tests recovery and pack/import/export,
  executes and inspects the standalone player, and reloads the Studio offline. Its first run exposed
  and then verified the fix for a stale active-cartridge label after `new`/`load`.
- Release-candidate verification: `./scripts/check.sh` passed Prettier, ESLint, strict root/runtime/
  Studio TypeScript checks, 42 Vitest tests, production asset generation/build, one full Firefox E2E,
  Rust formatting and Clippy with warnings denied, 45 Rust tests, native workspace build, and release
  `wasm32-unknown-unknown` build. Separate public-CLI calibration rebuilt, byte-compared, and exported
  every bundled cartridge.

## 2026-09-09 — V1 milestone 1: audit and immutable alpha baseline

- Started from `e39be5a`; the only initial addition was the supplied V1 brief. Read the handoffs,
  inspected manifests/tasks/implementation and passed the complete existing gate before changing
  implementation code. The first attempt stopped on brief formatting; formatting only that document
  allowed the rerun to pass all 42 Vitest / 45 Rust tests, Firefox E2E, native/Wasm and production builds.
- Added `COMPETITIVE_GAP_AUDIT.md` with the full required checklist, actual architectural gaps,
  consolidation strategy, verified measurements and explicitly untested areas. No scope was waived.
- Recorded actual production Firefox 155.0 Worker input/commands/state and indexed-output hashes
  over 240 intentional frames for each original game; archived exact alpha `.pxc` files, original
  first-install project records, final replay snapshots and a separately labeled synthetic save.
- New compatibility tests compare all 720 recorded framebuffer hashes using the production
  rasterizer and freeze 48 kHz stereo float32 PCM hashes using the production synth. Measured
  post-frame voice peaks are 4/5/5. Whole-path work peaks are 10,477/19,140/31,722, higher than alpha's
  earlier representative active-frame figures because these paths include title/start/transition work.
- Measured edit/save/run/first-render warm medians: 297.8 ms for original single-file Cinder and
  282.1 ms for a two-module split in an isolated test browser profile. Repository game sources and
  user browser data were not edited. Inspected the shell and all three game screenshots directly;
  retained captures under `output/playwright/` and exact bundle/cartridge hashes with the fixtures.
- Recorder development exposed an off-by-one observation boundary: host Promise continuations can
  run between Worker message listeners. Gating the game callback at execution time produced exactly
  240 contiguous renders/snapshots per retained trace. This was a harness issue, not a gameplay change.
- Checkpoint verification passed: focused Prettier/ESLint, runtime strict TypeScript and all three
  new compatibility tests. No production implementation has changed. Chromium and full PXCL
  headless re-execution remain required, not claimed by command-replay checks.
- Next: extract the Worker dispatcher into the shared production core, verify alpha parity, then
  implement actual Worker-owned hardware state and the Revision 1 bus/reference/conformance tests.

## 2026-09-09 — V1 milestone 2a: shared console dispatcher and replay correctness

- Extracted the existing Worker dispatcher into `createConsoleRuntime`. The Worker remains the
  restricted browser boundary; each core instance owns its scheduler, map/save state, command
  buffers and bounded debug trace. Graphics/audio ownership and the hardware bus are the next step,
  not yet implemented by this extraction. The standalone player is still a separate implementation.
- Native-compiled first-party sources now execute through that same core in tests and match all
  720 alpha frames' work, draw/audio commands, save writes and full state hashes. The retained alpha
  archive/project/trace files were not changed. Cinder's recorded JSON map views are reconstructed
  through the frozen project's production asset decoder rather than treated as native typed arrays.
- Added actual restore/forward checks. They initially failed for all three games: generated enum
  comparisons used JS object identity, while restore cloned the enum objects. Changed typed enum
  equality to variant/payload value equality; payload traversal charges the normal work budget.
  Payload-free game enums retain identical normal-play work and state hashes. A native compiler
  regression covers nested payload equality/inequality and replay in release and debug modes.
- Verified core instance isolation, per-frame buffer/debug reset, save flushing/restore, raster
  restrictions, draw ceiling and source-mapped work faults. Narrow lint initially rejected deprecated
  Vitest `toThrowError`; tests now use its supported `toThrow` API.
- `./scripts/check.sh` passed: formatting, ESLint, all strict TypeScript checks, **50 Vitest tests**,
  production builds, **one complete Firefox E2E**, Rust fmt/Clippy, **46 Rust tests**, native workspace
  and release Wasm builds. There were no skipped tests in the complete gate. The focused replay
  runs selected three tests; the full gate subsequently exercised all of them.
- Current repacked games are 42,851 / 41,262 / 38,039 bytes, including the new enum comparison helper;
  all remain below 64 KiB. These are intermediate V1 measurements, not replacements for alpha hashes.
- Next: Worker-owned graphics/audio backing state, real bus/register access and full Revision 1
  reference/inspection/conformance. The remaining brief checklist remains open. Nothing was pushed,
  published or deployed.

## 2026-09-09 — V1 milestone 2b: command-time device execution

- Split indexed graphics into begin-frame, ordered command execution and scanout completion;
  retained `executeFrame` as a wrapper over those operations. Raster/draw state still resets at the
  same frame boundary. Front/back storage now has stable identity instead of swapping array objects,
  which permits fixed hardware addresses without changing the recorded pixels.
- Split synth command execution from frame completion. Commands change voice/tracker state before
  rendering; sample generation and voice age advance only on completion. No second rasterizer or
  synthesizer was introduced. Snapshot restore cancels an unfinished graphics frame.
- Verification passed: runtime strict TypeScript, 20 focused graphics/audio/alpha compatibility
  tests (including all 720 browser pixel hashes and production PCM hashes), then 16 graphics/audio
  tests including two new command-time ordering/reset/timing checks, plus focused Prettier/ESLint.
- Next: move these actual device instances into the restricted shared core, remove Studio's
  execution copies, and attach the real Revision 1 bus. This preparatory checkpoint does not yet
  expose bus APIs or claim Worker ownership of graphics/audio.

## 2026-09-10 — V1 milestone 2c: Worker-owned graphics/audio and complete frame snapshots

- Studio player and debugger now present Worker-produced indexed pixels and PCM. The shared core
  decodes a bounded source asset bank and owns the actual rasterizer/synthesizer; map queries use the
  same visual store as drawing. The integration was retained in local commit `3e6d908` before this
  verification checkpoint. Standalone export still has its old separate implementation.
- Revision-2 core snapshots include graphics, audio and pending save writes as well as machine/save
  state. Restore validates structure and device references, rolling back all components and pending
  writes on failure. The debugger's existing journal wrapper now derives its data from this snapshot.
  Raw legacy Worker snapshots retain their original machine/save-only semantics; full public replay
  migration is still required. Boot graphics/audio commands retain alpha's discard behavior for now.
- Expanded native-compiled compatibility execution to compare the core's own indexed output, PCM,
  post-frame voice peaks and full device snapshot restore/forward behavior. All 720 alpha frame
  hashes, original work/commands/saves/state hashes and the three canonical PCM hashes match.
- Reproduced a malformed tracker order accepting inherited `__proto__` as a pattern. The validator
  now requires an own pattern entry. Added rejection checks for malformed pixels/PCM/voice state and
  pending-save queues. A too-strict field-count check initially rejected valid nine-field voices;
  corrected it and reran the focused suite (20 passed), followed by the full gate.
- `./scripts/check.sh` passed: Prettier, ESLint, strict TypeScript, **56 Vitest tests**, production
  builds, **one complete Firefox E2E**, Rust fmt/Clippy, **46 Rust tests**, native and release Wasm
  builds. No required tests were skipped. Production Worker/main JS now measure approximately
  45.46/116.52 kB; the ownership move transfers device code into the Worker. Games remain exactly
  42,851 / 41,262 / 38,039 packed bytes at this checkpoint. Chromium is not yet covered.
- Next: real byte/word/copy/fill APIs and live hardware backing stores, then the full Revision 1
  register/reference/conformance contract. No bus or V1 completion is claimed by this checkpoint.
  Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2d: byte bus and graphics backing storage

- Added checked byte/LE-word access, overlap-safe copy/fill, reserved/read-only handling and
  transactional writes over actual RAM, framebuffers, draw registers and all 144 raster records.
  The 22-bit address layout is a candidate subset, **not frozen Hardware Revision 1**. Visual-store,
  input, audio, save and system mappings, the viewer and the complete conformance cartridge remain.
  Most implementation was retained in local snapshot commit `38848d6` before this follow-up.
- Camera/clip registers use little-endian binary64 safe integers to preserve the existing PXCL Int
  range. Register-backed getters initially caused a substantial rasterizer slowdown; atomic drawing
  commands now latch their read-only register values outside pixel loops. Five alternating paired
  CPU measurements against `2bd8c4d` give 240-frame medians of 242.4→253.1 ms (Cinder), 246.1→218.6 ms
  (Ashvault), and 386.0→364.3 ms (Racer). `node scripts/measure-graphics.mjs` checks all 720 pixel
  hashes before timing. These shared-host samples are not edit-to-run or stable latency guarantees.
- Boot graphics/audio commands now execute on the same devices as bus writes; boot scanout does not
  advance machine time or voice age. This deliberately changes alpha's discarded boot commands;
  none of the three games depend on that behavior, and their recorded outputs remain identical.
  Core snapshot revision 3 retains writable bus storage; revision-2 migration initializes new RAM
  to zero, and malformed full restores roll back all devices. This remains frame-boundary replay.
- Ordinary PXCL conformance source exercises the public APIs through native Release/Debug builds
  and the real Firefox Worker. Tests cover address/value faults, work-before-allocation, byte order,
  aliasing, every raster row, reset/scanout and restore. New builtin names are installed lazily so
  old symbol identities and existing user-defined functions remain compatible.
- Firefox exposed enabled debugger controls before initialization had attached their handlers.
  Startup now disables controls until ready and cleans up on failure. Replay fingerprints also
  include indexed pixels and PCM: command-only fingerprints missed output changed by bus writes.
- Intermediate checks failed on measurement-script Node imports, a CommonJS-incompatible fixture
  path and Clippy's function-length limit; corrected each and reran the gate. Large typed-array
  assertions now use Node's full `deepStrictEqual` comparison to reduce test overhead; no timeout
  or behavioral assertion was weakened. The replay-output test was verified in a subsequent gate.
- `./scripts/check.sh` passed: formatting, ESLint, strict TypeScript, **68 Vitest tests**, production
  builds, **one complete Firefox E2E** (31.5 s), Rust fmt/Clippy, **47 Rust tests**, native and release
  Wasm builds. A separate full Vitest rerun also passed all 68 tests. All 720 alpha hashes and
  canonical PCM hashes pass. No required gate tests were skipped; Chromium coverage is still pending.
- Production main/Worker JS measure 117,845/52,685 bytes; Wasm is 1,167,303 bytes. Packed games remain
  42,851 / 41,262 / 38,039 bytes. Directly inspected 5× screenshots of four-player Racer, active
  Ashvault and Cinder's title under `output/playwright/v1-bus-*.png`. Manual Cinder start attempts
  did not enter play in this inspection; its automated scripted compatibility path passed. The
  known skipped-update input-edge question remains for explicit input conformance, not a guessed fix.
- Next: the real visual allocation table and shared map/tile/sprite storage, then remaining device
  mappings and full reference/conformance. Standalone still uses its old runtime and does not yet
  support the new bus APIs. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2e: real visual image and allocation descriptors

- Packed sprites, animation frames, tile pixels/flags, map layers and display defaults into one
  actual 128 KiB image. Renderer byte views and explicit little-endian map DataViews alias the bus;
  no host-endian word reinterpretation or alignment padding is used. Mapped display defaults retain
  their exact alpha cost and latch into live registers at frame start. Low-level pixel/index writes
  validate affected allocations transactionally; free tail bytes are writable scratch storage.
- Added bounded read-only asset/allocation descriptors and `visual_id(Text)`, with exact layout,
  costs, permissions and reset/timing documentation. Names resolve to deterministic ASCII-sorted IDs;
  map descriptors identify their tileset. These remain candidate addresses, not frozen Hardware
  Revision 1. Custom fonts and the remaining non-graphics devices are still required.
- Internal snapshots are revision 4 and retain modified visuals. Revision-3 migration preserves its
  bus state and reloads newly mapped visuals from source; revision-2 migration also zeroes work RAM.
  Malformed images and wrong layouts roll back without partial changes. Alpha archive/project files
  and the public packed format were not changed; full public replay migrations remain pending.
- Added five visual-store tests, revision-3 migration/rollback coverage and a public PXCL visual
  conformance project compiled in Release and Debug. The camera-culling regression now instruments
  the actual mapped DataView, checking exactly ten visible cells instead of an obsolete source array.
  Initial focused lint rejected nine void-expression callbacks; its standard fixes were applied and
  all checks rerun. No behavioral test or timeout was weakened.
- `./scripts/check.sh` passed: formatting, lint, strict TypeScript, **76 Vitest tests**, production
  builds, **one complete Firefox E2E** (21.5 s), Rust fmt/Clippy, **47 Rust tests**, native and release
  Wasm builds. Firefox now imports, recompiles and runs the visual conformance cart as well as the
  prior memory/debugger and full alpha workflows. All 720 frozen pixels/state/work/command traces
  and canonical PCM hashes pass. No gate tests were skipped; Chromium is still pending.
- The visual conformance project packs twice identically to **11,924 bytes**, SHA-256
  `d012f88b17c3b2184adc02a0f106d069769cedef2432da9b49253712486cdf0f`. This is a focused test
  project, not the finished service/stress cartridge or a claimed size-class showcase. Original
  games remain 42,851 / 41,262 / 38,039 bytes with unchanged intermediate-V1 hashes. Production
  main/Worker JS are 122,107/57,538 bytes; Wasm is 1,167,748 bytes.
- Ran two five-pair graphics measurements against `2bd8c4d`; all 720 pixel checks passed each time.
  Paired median CPU times per 240 frames were 345.0→413.9 / 367.9→324.4 / 501.0→508.4 ms, then
  287.2→273.5 / 307.2→231.3 / 358.3→350.6 ms (Cinder/Ashvault/Racer). The variation does not support
  a stable speedup or regression claim; these are rasterizer-only shared-host samples, not the
  required final edit-to-run measurement.
- Used the Playwright CLI for direct 5× visual inspection of `VISUAL BUS PASS` and `135B / 128K`,
  including the changed sprite/tile pixels. The first CLI upload lacked an active file chooser;
  clicking the existing OPEN control then uploading worked. Capture:
  `output/playwright/v1-visual-conformance.png`. The host control overlay is unchanged; clean capture
  remains a later requirement. Also inspected debugger frame 1, rewound to 0 and returned to 1;
  `output/playwright/v1-visual-debugger.png` retains that view. The CLI browser reported zero
  console messages/errors/warnings. Nothing was pushed, published or deployed.
- Next: controller and timing/RNG/work/status mappings with explicit input-transition conformance,
  followed by remaining audio/save/ROM mappings, full hardware viewer/reference and shared hosts.

## 2026-09-10 — V1 milestone 2f: authoritative controller MMIO

- Added read-only MMIO regions whose byte reads encode device-owned state directly. Controller
  masks and pointer registers use the scheduler's actual current/previous frames, also read by
  `btn`, `btnp` and pointer APIs. No shadow input image or new snapshot revision is needed; existing
  frame snapshots restore both high-level and bus observations. Reads/copies retain normal byte-bus
  costs; writes and cross-region writes into these registers fail transactionally.
- Reproduced alpha's 30 Hz edge timing with a controlled scheduler test: an odd-frame press appears
  in drawing, but the following update sees held=true and pressed=false. Restore reproduces it.
  Documented this frame-sampled behavior without changing any original game/control code. This
  checkpoint does not add update-latched input, four-port keyboard remapping or accessibility UX.
- The public input fixture tests every button on all four ports, current/previous/pressed/released
  masks, pointer coordinates/edges, reset, MMIO-to-RAM copy and restore. Native Release/Debug tests
  each exercise 36 scripted frames at both 30 and 60 Hz. Its initial array `const` declarations failed
  PXCL's existing compile-time-expression restriction; using fixed state arrays made the fixture
  valid without changing the language or weakening validation.
- Found and reproduced two boundary defects while checking malformed input. A pointer outside the
  screen failed only after the core had reset live draw registers; the core now validates before
  any frame reset. A four-slot sparse controller array passed `.every` because holes were skipped;
  validation now checks all four actual entries and rejects extra enumerable array fields. Focused
  regressions failed first, then passed with the corrections and full-state equality assertions.
- `./scripts/check.sh` passed: formatting, lint, strict TypeScript, **84 Vitest tests**, production
  builds, **one complete Firefox E2E** (24.4 s), Rust fmt/Clippy, **47 Rust tests**, native and release
  Wasm builds. Firefox runs the input fixture with real keyboard presses on both existing mappings.
  All frozen alpha traces/PCM still pass. No complete-gate tests were skipped; the failed filtered
  reproductions intentionally selected individual tests before the subsequent complete run.
- Packed games and their intermediate-V1 hashes are unchanged at 42,851 / 41,262 / 38,039 bytes.
  Main/Worker JS are 122,185/58,507 bytes; Wasm remains 1,167,748 bytes. No separate visual-layout
  change was made; the preceding checkpoint's inspected screens remain the latest manual captures.
  Chromium, controller remapping and the remaining V1 acceptance work remain open.
- Next: actual frame/update/time/RNG/work/fault registers and matching snapshot semantics, followed
  by audio/save/ROM and the full viewer/conformance/shared-host work. Hardware Revision 1 is still
  incomplete. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2g: fixed work ceiling and restorable accounting primitive

- Auditing system-register inputs exposed a contradiction: HARDWARE/LIMITS documented 50,000 work
  units, but the load protocol and core accepted larger budgets. Two focused tests reproduced it.
  The ceiling is now an explicit hardware constant, enforced by the shared configuration schema
  before cartridge construction. Studio uses that constant; lower internal diagnostic budgets remain
  supported. The core now validates the complete configuration with the Worker protocol's schema.
- Added a revisioned work-budget snapshot primitive retaining used units, limit and exact source
  attribution. Restore validates counts, ordering, spans, duplicates, totals and limit agreement
  before mutation. It is tested independently but **not yet wired into aggregate machine snapshots
  or mapped system registers**; that integration is the next checkpoint, not claimed here.
- Enormous finite integer work charges now fault with a representable saturated counter/attribution
  total at `2^53-1`, rather than leaving unsafe integer accounting. Ordinary charges and source fault
  positions are unchanged. Tested both safe-integer addition overflow and larger geometric-scale
  charges, as well as malformed/sparse budget snapshots and transactional rejection.
- `./scripts/check.sh` passed: formatting, lint, strict TypeScript, **88 Vitest tests**, production
  builds, **one complete Firefox E2E** (23.9 s), Rust fmt/Clippy, **47 Rust tests**, native and release
  Wasm builds. The two admission reproductions failed first and passed after enforcement. No complete
  gate tests were skipped; all alpha output/work/state/PCM compatibility checks still pass.
- Original games remain 42,851 / 41,262 / 38,039 packed bytes. Main/Worker JS measure 122,239/60,078
  bytes; Wasm remains 1,167,748 bytes. No visual layout changed; no additional manual capture was
  needed for this boundary change. Chromium and the remainder of V1 verification are still open.
- Next: integrate accounting, execution/fault status and deterministic counters into complete machine
  snapshots and real system MMIO, retaining explicit legacy migrations. Hardware Revision 1 remains
  incomplete. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2h: authoritative system registers and execution snapshots

- Added read-only system MMIO at `0x50200`: completed frame/update counts, frame-derived binary64
  time, actual RNG state, cadence, callback phase/scanline, charged work/limit and terminal fault
  status/source span. Reads encode device-owned state directly; no shadow register image is saved.
  All four callback phases and all 144 scanlines are exercised by ordinary PXCL conformance source.
- Machine snapshot revision 2 now retains boot/counter/cadence, work accounting/attribution and fault
  boundaries; aggregate core snapshots advance to revision 5. Legacy core revisions 1–4 explicitly
  require their original revision-1 machine shape. Migration derives update counts, defaults missing
  accounting to zero/empty and phase/fault to idle/none, and preserves boot status or infers boot
  completion from a nonzero frame. Existing graphics/audio/visual migration behavior remains tested.
- Faults retain their original phase, line, source span and work usage. Retry fails before per-frame
  device reset; restoring a healthy checkpoint permits execution, while restoring a faulted one keeps
  it terminal. Frame counters fault at the exact-integer ceiling rather than wrapping. Snapshot
  validation rejects inconsistent counter/phase/configuration/accounting, and cartridge restore
  failure rolls back cartridge state. Live-callback snapshots are explicitly rejected: source-level
  suspension is still unimplemented, not implied by the new phase metadata.
- Added native Release/Debug system conformance at both 30 and 60 Hz, binary register/time capture,
  RNG alias checks and full replay equality. Firefox compiles and runs the fixture in the real Worker,
  then steps/rewinds/replays a debug frame. Alpha compatibility now projects the original six-field
  machine format when hashing old state; **no immutable fixture was regenerated or edited**.
- `./scripts/check.sh` passed: formatting, lint, strict TypeScript, **105 Vitest tests**, production
  builds, **one complete Firefox E2E** (25.4 s), Rust fmt/Clippy, **47 Rust tests**, native and release
  Wasm builds. An initial focused lint run found test callback/style issues plus a defensive typed
  cadence check; these were corrected. The first full gate stopped on test formatting after lint's
  autofix; formatting was applied and the entire gate rerun successfully. No final-gate tests skipped.
- Games remain 42,851 / 41,262 / 38,039 bytes with the same hashes recorded above. Main/Worker JS
  measure 124,782/64,673 bytes; Wasm remains 1,167,748 bytes. All frozen alpha output/work/state/PCM
  traces pass. No visual-layout change or additional manual screenshot was made; Chromium remains
  open alongside the rest of the V1 stopping contract.
- Next: audio control/status backed by the existing synthesizer, then save commits/ROM and the
  viewer, complete conformance and shared-host work. Hardware Revision 1 is still incomplete.
  Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2i: audio-state validation before writable controls

- Two focused regressions reproduced accepted unsupported waveforms and sparse eight-voice
  snapshots. Tightened sound/tracker shape and numeric validation: known oscillator kinds, present
  finite levels/pan/duty, dense tables/orders/rows, boolean looping and finite cell volumes. Pitch
  effects must retain a finite worst-case frequency over all tracker notes and the complete voice
  lifetime. This rejects malformed/extreme data that previously could admit non-finite oscillator
  state; normal synthesis calculations are unchanged.
- Audio assets are copied into the validated owner. Snapshot restore rejects missing patch references
  and active voices beyond their patch lifetime before mutation. Tests cover sparse arrays with an
  extra-property disguise, malformed JSON through the public codec, unsafe pitch, valid extreme pitch,
  caller mutation after load and transactional rejection. Writable audio MMIO is **not implemented
  in this checkpoint**; these checks establish its necessary state-validation boundary.
- `./scripts/check.sh` passed: formatting, lint, strict TypeScript, **110 Vitest tests**, production
  builds, **one complete Firefox E2E** (26.6 s), Rust fmt/Clippy, **47 Rust tests**, native and release
  Wasm builds. Both initial reproductions failed before the correction. A focused lint check rejected
  the test's deliberate array deletion; it now constructs that malformed case through reflection.
  Final-gate tests were not skipped; all immutable alpha frame/work/state/PCM checks pass.
- Packed games retain the preceding sizes/hashes. Main/Worker JS measure 125,446/65,341 bytes;
  Wasm remains 1,167,748 bytes. There is no visual-layout change or new manual screenshot. Audio
  controls, save/ROM, Chromium and the remaining Hardware/V1 acceptance work are still open.
  Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2j: writable synth/tracker MMIO and output fault boundaries

- The byte bus now supports side-effect-free preparation of device writes followed by commit only
  after every destination validates. Focused tests exercise overlapping copies, RAM/device aliasing,
  invalid values, cross-region permissions and raster restrictions with no partial commits. MMIO
  owners retain their own snapshots; the bus does not save a second register image.
- Mapped synth status at `0x51000`, tracker selection/position at `0x51020`, eight 64-byte voice
  records at `0x51100`, and immutable name-sorted audio descriptors at `0x3c0000`. Voice controls use
  the existing exact binary64 note/volume/phase and integer age/noise state. High-level commands and
  raw reads/writes share the same objects. `audio_id(Text)` is lazily typed like `visual_id`, preserving
  old symbol IDs. Layouts, read-only allocation fields, timing, raw activation and stopped-tracker
  behavior are documented. Aggregate snapshot revision 5 remains sufficient: synth state already
  retains every mapped mutable field.
- Reproduced audio allocation overflow and corrected the output-stage boundary. Scanout and audio
  mixing now run in machine phase 5 before its completed-frame increment. Audio/frame allocation
  exhaustion faults with PX9012 before overflow; output failures latch phase/counters/source status
  and reject retry before reset. Healthy and faulted checkpoint restore are tested. Normal synthesis
  calculations, game scheduling and all frozen alpha PCM/frame/work/state traces remain unchanged.
- Added ordinary `tests/conformance/audio` source/assets. Native Release/Debug cases exercise all
  eight voices, descriptors, high/low aliases, raw-muted versus audible PCM and complete replay. A
  restored boundary test exposed the fixture's low-word comparison at frame 65,536; the assertion now
  compares low words, while the host test checks copied 64-bit counters across 65,535/65,536. This was
  a fixture defect, not hardware-counter wrap. Both compiler modes failed first and passed afterward.
- `./scripts/check.sh` passed after that correction: formatting, lint, strict TypeScript,
  **118 Vitest tests**, production builds, **one complete Firefox E2E** (24.7 s), Rust fmt/Clippy,
  **47 Rust tests**, native and release Wasm builds. An earlier complete run also passed before the
  additional rollover test (27.5 s Firefox). The output-exhaustion reproduction initially failed;
  a focused lint issue with closure-updated output narrowing was resolved without disabling the
  rule. No final-gate tests were skipped; focused reproductions selected subsets intentionally.
- The final audio conformance artifact packs identically twice at **15,309 bytes**, SHA-256
  `1155cf4d01bd45603f81e53c7164adc77178a23729cb3a5ae665b145d3662594`. It is conformance proof, not a
  substitute for the required size-coded showcases. Original games remain 42,851/41,262/38,039 bytes
  with unchanged hashes. Main/Worker JS are 129,252/69,424 bytes; Wasm is 1,168,140 bytes.
- Using the Playwright CLI skill, manually imported/ran the fixture in headed Firefox, inspected
  `AUDIO BUS PASS` at 5x integer scaling, and inspected the eight-voice debugger panel after stepping,
  rewinding to zero and replaying frame one. Reimported the corrected final artifact and inspected
  its screen again (`output/playwright/v1-audio-conformance.png`); console errors/warnings were zero.
  `v1-audio-debugger.png` records the earlier equivalent frame-one panel. The existing player control
  overlay and debugger layout are unchanged; this is not a clean-capture/UI-redesign claim. Browser
  and owned preview server were closed. No subjective audible-quality judgment was made.
- Next: verify initialization-time runtime calls, then save commits/ROM, the full viewer and shared
  hosts. Hardware Revision 1 is still incomplete. Chromium and all remaining V1 stopping requirements
  remain open. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2k: runtime-call globals execute inside boot

- Reproduced PX9102 in native Release and Debug when a mutable global initializer called `mem_read`:
  generated factories executed initializers while the core was still constructing its machine.
  The emitter now generates an initialization routine invoked first by `start()`, after attachment
  and before `on start`. Initializers retain linked declaration order and run in the existing start
  phase/budget with real devices. No eager attachment of a partially constructed machine is needed.
- Added the public boot fixture for reset RAM, RNG, palette/drawing aliases, phase/status, retained
  initializer work, single initialization across frames and full replay. Exact-budget admission and
  one-unit-below rejection verify the combined initializer/start budget and the final call's exact
  source span. A Rust execution test checks both modes: factory construction makes no runtime calls
  and initializes no globals; `start()` initializes them before the callback. This low-level factory
  timing change is documented; booted snapshots and all legacy alpha fixtures remain compatible.
- `./scripts/check.sh` passed: formatting, lint, strict TypeScript, **120 Vitest tests**, production
  builds, **one complete Firefox E2E**, Rust fmt/Clippy, **48 Rust tests**, native and release Wasm
  builds. The first full attempt stopped on a nested test matcher's unsafe `any`; an exact span value
  replaced it, and the full gate reran successfully. No final-gate tests skipped. All frozen alpha
  frame/work/state/PCM traces pass. No UI layout changed or additional manual screenshot was taken;
  the immediately preceding headed Firefox inspections remain the latest visual check.
- The emitted wrapper changes packed bytes, not game source or observed play. Current game artifacts:
  Cinder Circuit **42,904 bytes**, SHA-256
  `225f164cc7cb9a891b353fb41df025d7a4d9be09ef713888c4f7a8b766408ea8`;
  Ashvault **41,315 bytes**, `44abf7399348c4790de27ad316d63fcfea1c064e3c99980c644026e75d604986`;
  Raster Rush **38,091 bytes**, `3f4172ea7f5538d860143f555a9243dac38449e4a51cabffab8b2279ab41d5b1`.
  The increases from the preceding checkpoint are 53/53/52 bytes. Main/Worker JS remain
  129,252/69,424 bytes; Wasm is 1,168,292 bytes.
- Repacked conformance artifacts twice and compared byte-for-byte: audio **15,355 bytes**,
  `860851df9f1700c218879cbafb81871f5701c9f6329eb673412dc21efe1c31d9`; visual **11,967 bytes**,
  `9e60c60547ee72f1444af56f7a603075d0d95d5d835a179e844a90fad29f9a89`.
- Next: authoritative save bytes and explicit commit semantics, preserving legacy integer-save
  behavior and persisted values, followed by ROM/viewer/shared-host work. Hardware Revision 1 and
  the remaining V1 contract are still incomplete. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2l: authoritative save image and explicit commits

- Recovered an unlogged inherited implementation in commit `38b7406` and audited it before extending
  it. The Worker now owns one byte-exact 8 KiB working save image plus a committed latch. Raw MMIO at
  `0x58000` and read-only committed bytes at `0x5a000` share this state; `0x50500` exposes an atomic
  full-image commit command, dirty/pending flags, fixed capacity, commit count and changed-byte count.
  Commit preparation charges all 8,192 units before mutation and range writes remain transactional.
- The legacy sorted-JSON integer API aliases the same bytes. `save_set_int` deliberately retains its
  alpha auto-commit behavior while `save_commit` supports binary/raw users. Invalid binary data makes
  integer calls fault without replacing the image. Host output delivers cloned complete images only
  after successful frames; Studio now persists those exact bytes rather than rebuilding JSON.
- Aggregate snapshots advance to revision 6 and retain working/committed bytes, pending state and
  count. Legacy revisions 1–5 migrate their integer objects into both images; malformed/sparse state
  rejects before mutation. The existing alpha save fixture and all frozen game traces remain intact.
- Added ordinary `tests/conformance/save.pxl` plus Release/Debug native runs for initial host bytes,
  raw/high-level aliasing, status, explicit/compatibility commits, host output and restore/forward
  equality. Firefox now persists a seed save, edits that same project's source, then runs the public
  conformance program against the retained identity. This also verifies source edits do not erase
  progress. `./scripts/check.sh` passed: formatting, lint, strict types, **129 Vitest tests**,
  production builds, **one complete Firefox E2E** (44.7 s), Rust fmt/Clippy, **48 Rust tests**,
  native and release Wasm builds. A preceding focused browser run also passed in 59.8 s.
- The initial untouched gate at `e70f99a` passed after installing the repository-pinned host tools:
  formatting, lint, strict types, **127 Vitest tests**, production builds, **one Firefox E2E**,
  Clippy, **48 Rust tests**, native and release Wasm builds. The first attempts correctly stopped on
  absent pnpm/generated Wasm bindings/target; no code was changed until setup and the baseline passed.
- No packed game source or output semantics changed in this checkpoint. Hardware Revision 1 remains
  incomplete until immutable cartridge ROM/metadata and the full memory viewer/conformance freeze.
  Chromium and the remaining V1 milestones are still open. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 2m: immutable cartridge ROM and hardware memory viewer

- The trusted host now supplies a cloned canonical cartridge image to the production Worker. The
  byte-exact image is read-only at `0x60000`; a 64-byte status block at `0x50600` reports hardware
  revision, format revision, length, fixed capacity, base, presence/canonical flags and entry count.
  Oversize images reject at configuration validation, unmapped absence remains a reserved hole, and
  both the status and image reject writes. Studio run and debug first pack the active project, so the
  mapped bytes are the same source-visible artifact used for export.
- Added a strict debug-only Worker request/response path for bounded memory reads and edits. Reads
  return the production bus bytes plus region names/bounds/permissions. Edits are transactional,
  uncharged host operations at idle message boundaries and still use device validators; release
  runtimes, read-only regions and reserved holes reject them. Debug edits to the save command do not
  accidentally consume cartridge frame work.
- Replaced the debugger's placeholder memory summary with the real MEMO panel: hexadecimal addresses,
  1–64 byte HEX/DEC views, changed-byte markers, region labels and permissions, safe single-byte
  paused edits, eight byte-change watchpoints, and a Hardware manual shortcut. The existing source,
  state, task, profile, audio, replay and control surfaces remain available. Firefox E2E reads RAM in
  both number formats, edits it, trips a watchpoint on the next frame, and follows the manual link.
- Unit/conformance coverage now checks bus inspection/edit transactionality, protocol validation,
  ROM cloning/status/permissions, debug/release access and public PXCL ROM reads. A first Firefox run
  exposed an unhandled service-worker registration `AbortError` during the existing intentional
  offline reload; its trace located the aborted best-effort registration. Registration now handles
  navigation aborts without hiding other failures, and the unchanged complete workflow passed on
  rerun in 25.9 s with no browser errors.
- The final complete repository gate passed: Prettier, ESLint, strict TypeScript, **132 Vitest
  tests**, production builds, the complete Firefox E2E (**25.2 s**), Rust fmt/Clippy with warnings
  denied, **48 Rust tests**, and native/release Wasm builds. A preceding complete run with 131
  Vitest tests and the same browser coverage also passed before the focused debugger-save accounting
  assertion was added.
- Both packings of every original game remain byte-identical to the preceding checkpoint: Cinder
  Circuit **42,904 bytes**, SHA-256
  `225f164cc7cb9a891b353fb41df025d7a4d9be09ef713888c4f7a8b766408ea8`; Ashvault **41,315 bytes**,
  `44abf7399348c4790de27ad316d63fcfea1c064e3c99980c644026e75d604986`; Raster Rush **38,091
  bytes**, `3f4172ea7f5538d860143f555a9243dac38449e4a51cabffab8b2279ab41d5b1`.
  Current main/Worker/Wasm outputs are 137,148/75,926/1,168,672 bytes before the full gate.
- Next: freeze the complete conformance/service cartridge and shared headless/standalone execution.
  Hardware Revision 1 is not yet declared complete. Chromium and the remaining V1 milestones remain
  open. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 3a: shared headless/standalone core and golden game replays

- Added `px240c run PROJECT_OR_PXC --headless` on the existing CLI surface. It accepts an unsigned
  seed, 0–36,000 frames, compact duration-aware four-port/pointer trace JSON, an optional raw 8 KiB
  save and an optional result path. Revision-1 output records per-frame framebuffer/state/audio
  command/little-endian Float32 PCM/save SHA-256 and work, aggregate hashes/peak and modeled fault
  code/span. Project and `.pxc` inputs produce identical output; imported artifacts are bounded,
  reconstructed and recompiled from source before execution rather than trusting archived JS.
- The generated 149,795-byte Node adapter directly drives `createConsoleRuntime`, the production
  core used by the browser Worker. Focused host tests cover deterministic output, modeled faults and
  malformed traces; CLI integration covers project/raw cartridge parity, explicit seed, compact
  input and initial save. Node is a CLI host dependency and is not exposed to cartridge code.
- Replaced the hand-written standalone emulator with a generated 179,384-byte host containing an
  inline build of the same locked-down `sandbox-worker.ts` and production core as Studio. Exports now
  embed the exact canonical ROM, authoritative assets, indexed output/PCM and byte-save commits.
  Legacy standalone JSON saves migrate into an isolated V1 cartridge key. Firefox's complete E2E,
  including standalone play/source inspection and offline Studio reload, passed in **26.5 s**.
- Added intentional compact replay paths and golden results for all three original games. Cinder
  Circuit's 120 frames peak at **3,498 WU** and end with framebuffer/state/audio-command/PCM hashes
  `7d94f65d...` / `b09b01d5...` / `6c3241a1...` / `c3c2895d...`; Ashvault's 30 frames peak at
  **19,140 WU** and end `7a954d16...` / `98e2a72c...` / `3526f248...` / `82bc2372...`; Raster
  Rush's 120 frames peak at **28,140 WU** and end `d133c8d0...` / `fe417b70...` / `11af7f6c...` /
  `ca00a064...`. Automated CLI tests also lock beginning/middle/end framebuffer checkpoints and the
  complete original cartridge hashes.
- Added `px240c-service`, an ordinary source-visible PXCL service cartridge with eight diagnostic
  pages and live public-API checks for reset/bus/display/raster/input/audio/save/ROM/scheduler/RNG/
  tasks. It is now a fourth built-in Studio cartridge, packs byte-identically at **27,869 bytes**,
  SHA-256 `0175b0e7d06bd401ee48ef695b095cdbdf78a0832b1acd9dc88648322a0f12b8`, and completes five
  headless frames at a **5,130 WU** peak without fault.
- Original game artifacts remain unchanged at 42,904/41,315/38,091 bytes with the prior hashes. The
  main/Worker JS outputs are now 137,165/75,926 bytes. Embedding the shared standalone implementation
  in the Rust/Wasm exporter increases Wasm from 1,168,672 to **1,314,950 bytes** and the formatted
  generated standalone player from 33,091 to **179,384 bytes**; this is explicit host/distribution
  cost, not cartridge size. The complete repository gate passed after two Clippy findings drove a
  smaller host-process helper: Prettier, ESLint, strict TypeScript, **134 Vitest tests**, production
  builds, complete Firefox E2E, Rust fmt/Clippy with warnings denied, **50 Rust tests**, native and
  release Wasm builds. Cross-browser parity and the remaining V1 milestones remain open. Nothing was
  pushed, published or deployed.

## 2026-09-10 — V1 milestone 4a: namespaced projects, tests, and live external loop

- Extended PXCL/1 project linking without changing single-file meaning. Top-level declarations are
  public by default, may use explicit `pub`, and may use `private` to reject imported access.
  Dependency modules now own separate namespaces: duplicate constants/state/functions/tasks/records/
  enums are deterministically linked, qualified aliases resolve the correct owner, local shadowing is
  retained, dependencies initialize before importers, and cycles/dependency callbacks remain stable
  project errors. Core fixtures cover aliases, visibility, duplicate public and private names, local
  shadowing, missing private members, and cycle paths.
- Added `px240c test PROJECT`. Sorted ordinary `.pxl` test entries run compiler-produced debug code
  for a deterministic frame, `*.fail.pxl` locks an expected stable diagnostic, and revision-1
  `*.pxrun.json` files accept frames, seed, compact input, raw save fixture, and arbitrary headless
  summary expectations including framebuffer/state/audio/save hashes. Integration tests exercise all
  three modes and source-located runtime faults. `tests/` PXCL sources are excluded from canonical
  release archives.
- Expanded the stdio LSP with project completion, cross-file definition/references/rename,
  signature help, dependency-aware diagnostics, canonical formatting, and document/workspace
  symbols. Editing a module republishes it and direct importers rather than unrelated open files;
  tests exercise a public member across two modules and verify a later `private` edit invalidates its
  importer. The same Rust lexer/parser/compiler remains behind CLI, Wasm and Studio builds.
- `fmt` and `check` now default to the current project, and `fmt` recursively handles project source.
  Long-running `watch` serves a loopback-only source-inspectable player, hashes bytes, preserves the
  last good output on a failed build, and reloads after a successful revision. A real TCP integration
  test edits a watched project and observes revision 1 become revision 2; `--no-open` supports CI.
- Added the required stable `LANGUAGE.md` and `TOOLS.md` entry points and updated PXCL grammar/tool
  behavior. The complete repository gate passed: Prettier, ESLint, strict TypeScript, **134 Vitest
  tests**, production builds, complete Firefox E2E in **35.5 s**, Rust fmt/Clippy with warnings
  denied, **57 Rust tests**, native and release Wasm builds. The original games and service cart
  remain byte-identical. Main JS grew 31 bytes to **137,196**; compiler Wasm grew 36,894 bytes to
  **1,351,844**; Worker and generated host/player remain 75,926 / 149,795 / 179,384 bytes. The shared
  original-file project index, Studio cross-file UX, folder-backed editing, repeat latency sample,
  and genuine debugger suspension remain open. Nothing was pushed, published or deployed.

## 2026-09-10 — V1 milestone 5a: live statement suspension

- Debug generation now emits resumable generator code and yields immediately before executable
  global initializers and statements. Nested routines, loops, callbacks and serialized task
  continuations suspend through the same path; call stacks and locals remain live while stopped.
  Release generation is unchanged and contains no debug yields or resumable metadata.
- Added an explicit debug boot boundary. `on start` can be stepped without advancing frame time,
  then completes before frame 0. Each frame samples input once and holds it across all statement
  stops. Graphics, audio, save output and replay journal advancement remain deferred until the
  frame completes. Frame execution still drives the same resumable cartridge to completion, so
  headless tests and ordinary debug play retain prior semantics.
- Added a validated Worker `debug-step` exchange and rewired Studio's IN/OVER/OUT, run and frame
  controls to advance the live continuation instead of navigating a completed-frame trace. Source
  breakpoints and restricted conditions are tested at the actual pre-statement boundary. Paused
  inspectors show live globals/tasks/stacks; memory edits remain transactional, and rewind discards
  an unfinished continuation and restores the last completed boot/frame snapshot.
- Focused verification passed strict TypeScript, 40 runtime/protocol/hardware tests, and a native
  compiler execution test that observes suspension inside a nested call, loop and task. The complete
  repository gate then passed formatting, ESLint, strict TypeScript, **135 Vitest tests**, production
  builds, the full Firefox E2E in **30.5 s**, Clippy with warnings denied, **58 Rust tests**, native
  and release Wasm builds. Firefox exercised pre-initializer, boot and callback statement stops; its
  cold-offline visit now waits for the preceding controlled online reload to finish before severing
  the network. Original cartridge artifacts remain byte-identical at 42,904 / 41,315 / 38,091 /
  27,869 bytes and retain their previously recorded SHA-256 hashes.
- Current generated host sizes are 155,782-byte headless, 186,411-byte standalone, 138,999-byte
  Studio main JS, 79,373-byte Worker JS and 1,361,437-byte compiler Wasm. Cross-module original-file
  source maps, breakpoint edit remapping and the remaining debugger matrix are the next work in this
  milestone; no debugger-completion or V1-completion claim is made. Nothing was pushed, published or
  deployed.

## 2026-09-11 — V1 milestone 5b: original-module debugging and persistent breakpoints

- Project debug builds now retain a byte-boundary origin map while imports and colliding symbols are
  rewritten into the linked compiler input. Source-map v3 output lists every reachable original
  module and its exact content; statement events and call-stack frames carry original module paths
  and offsets. Release compilation still uses its prior linked map, preserving canonical cartridge
  bytes and all four existing artifact hashes.
- Studio follows live stops across modules, shows module-qualified stack/source locations, and keys
  breakpoints by module plus line. Breakpoints are stored locally per project with bounded revision-1
  data. On reopen or an edit, exact trimmed-statement anchors move to the nearest matching line;
  deleted statements and malformed/oversize storage are discarded without blocking the debugger.
- Added compiler mapping tests across an aliased dependency, protocol rejection for malformed source
  names, pure breakpoint-remapping coverage, and a production Firefox workflow that imports a real
  two-module cartridge, steps from the entry callback into its dependency, stops on a dependency
  breakpoint, closes the Worker, reopens the debugger, and hits the persisted breakpoint again.
  The complete repository gate passed formatting, ESLint, strict TypeScript, **136 Vitest tests**,
  production builds, the expanded Firefox E2E in **52.9 s**, Clippy with warnings denied, **59 Rust
  tests**, native and release Wasm builds. No required gate check was skipped.
- Added the required canonical `docs/DEBUGGING.md`; the former alpha filename remains as a
  compatibility link. Work-attribution/profile locations still use linked spans, while executable
  statements and stacks use original files. Debugger fault/pause-audio matrix coverage and final
  Chromium parity remain open. Current generated sizes are 155,782-byte headless, 186,865-byte
  standalone, 141,783-byte Studio main JS, 79,373-byte Worker JS and 1,368,539-byte compiler Wasm.
  Nothing was pushed, published or deployed.

## Current risks (V1 work in progress)

- The asset editors intentionally expose a compact alpha subset: one map tileset, one editable
  raster row, and no custom font asset decoding/editor.
- Folder-backed editing and incremental compiler invalidation beyond direct importer diagnostics
  remain open.
- Broader WebGL2/Web Audio device coverage remains beyond the local Firefox validation.
- Broader worker-hardening audits remain; the current boundary must not be described as stronger
  isolation than the browser actually provides.
