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

## Current risks (alpha baseline; V1 work in progress)

- The asset editors intentionally expose a compact alpha subset: one map tileset, one editable
  raster row, and no custom font asset decoding/editor.
- Linked revision-1 modules must have globally unique top-level names; generated project source maps
  currently identify the deterministic linked source rather than each original module.
- Breakpoints stop after the containing frame; source steps navigate captured probe events rather
  than suspending synchronous JavaScript in the middle of a callback.
- LSP references/rename are currently same-document and full-document-sync only.
- Broader WebGL2/Web Audio device coverage remains beyond the local Firefox validation.
- Broader worker-hardening audits remain; the current boundary must not be described as stronger
  isolation than the browser actually provides.
