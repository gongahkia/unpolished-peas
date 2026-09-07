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

## Current risks

- Project-wide import linking, full hardware facilities, studio tools, debugger, packer, LSP,
  exporter, and games remain to be built.
- WebGL2 and Web Audio behavior will need both state tests and hands-on browser inspection.
- Broader worker-hardening audits remain; the current boundary must not be described as stronger
  isolation than the browser actually provides.
