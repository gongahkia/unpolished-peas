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

## Current risks

- Three bundled games and their final limit calibration remain to be built.
- The asset editors intentionally expose a compact alpha subset: one map tileset, one editable
  raster row, one tracker pattern, and no custom font editor.
- Linked revision-1 modules must have globally unique top-level names; generated project source maps
  currently identify the deterministic linked source rather than each original module.
- Breakpoints stop after the containing frame; source steps navigate captured probe events rather
  than suspending synchronous JavaScript in the middle of a callback.
- LSP references/rename are currently same-document and full-document-sync only.
- Broader WebGL2/Web Audio device coverage remains beyond the local Firefox validation.
- Broader worker-hardening audits remain; the current boundary must not be described as stronger
  isolation than the browser actually provides.
