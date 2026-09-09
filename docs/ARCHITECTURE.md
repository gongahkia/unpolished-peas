# Architecture

PX-240C is a static browser application backed by one compiler and cartridge implementation shared
with a native Linux CLI.

## Package ownership

- `crates/pxcl-core`: PXCL syntax, semantic analysis, typed IR, code generation, debug metadata,
  deterministic cartridge encoding, standalone HTML export, formatter, and language-service
  analysis.
- `crates/pxcl-wasm`: a deliberately narrow WebAssembly boundary over `pxcl-core`.
- `crates/px240c-cli`: native command family and stdio language server, both using `pxcl-core`.
- `packages/runtime`: deterministic hardware model, worker protocol, indexed graphics, input, audio,
  persistence adapters, debugger, replay, and export support.
- `apps/studio`: 240x144 shell and integrated tools. It consumes the runtime and compiler bridge but
  owns neither compiler rules nor cartridge execution.

Dependencies point inward: studio -> runtime/WASM bridge -> compiler core. Cartridge code runs only
in a dedicated worker and communicates through a versioned, validated message protocol. It never
receives persistence handles or DOM objects.

The Worker delegates scheduling, console dispatch, work accounting, graphics, audio, maps, saves
and debug traces to `packages/runtime/src/console-runtime.ts`. That core validates its complete
configuration with the same schema as the Worker protocol, rejects budgets above 50,000, and decodes a
bounded source asset bank; map queries and drawing use the same visual store. Commands execute in
program order, then frame completion resolves indexed scanout and renders deterministic PCM.
The page presents those pixels/samples and handles input and storage; it no longer re-executes
cartridge graphics or audio. Tests drive this same core with native-compiled PXCL and compare
actual alpha browser recordings. `MemoryBus` now aliases work RAM and the actual graphics/raster
storage with transactional byte/word/copy/fill access. Its candidate layout and implemented subset
are documented in HARDWARE; the remaining devices and public headless CLI are still required.

## Data flow

PXCL source is tokenized, parsed, resolved to stable symbol IDs, type-checked against a typed asset
catalog, and lowered to a serializable structured IR. That IR is instrumented and generated as
compact JavaScript plus source maps; the same IR produces debug and release output.
Projects remain Git-friendly directories; packing creates a canonical, content-addressed `.pxc`
artifact containing original source and compiled output.

Standalone export deliberately reuses the pack/decode boundary: verified archive entries are
embedded with a small revisioned browser player rather than rebuilding a parallel project model.
The Vite build emits a service worker from the final hashed asset inventory, so offline caching
tracks the actual build instead of a handwritten filename list.

Debug output adds source probes and routine enter/leave hooks without changing typed IR. The worker
returns bounded traces and serializable state/task inspection only when debug mode is requested.
The revision-5 Worker snapshot includes the scheduler, saves and pending writes, indexed-framebuffer,
synthesizer and retained bus state. Restore validates all components and rolls back on a device-reference failure.
The Studio journal still retains its revision-1 wrapper, now populated from that authoritative
snapshot; recorded inputs and canonical fingerprints provide deterministic rewind with explicit
divergence detection. Raw legacy Worker snapshots restore only their original scheduler/save fields;
they do not contain graphics/audio. Full public replay migration remains required. The debugger does
not grant cartridges DOM, persistence, or network capabilities.

Visual assets now occupy one packed 128 KiB image. Byte views back pixels/flags and explicit
little-endian DataViews back map cells; the renderer and map query API read those views directly.
Display defaults also occupy their charged bytes, with frame-start latching into live registers.
Read-only descriptors expose allocation order and exact sizes. Legacy revision-3 bus snapshots
migrate the new visual region from source, while current snapshots retain all mutable visual bytes.
Read-only controller/pointer MMIO encodes the scheduler's actual current/previous input frames;
there is no shadow input buffer to synchronize or independently restore. Core input validation
precedes graphics resets; direct `DeterministicMachine` callers are validated at its frame boundary too.
System MMIO likewise encodes the real scheduler, RNG and work ledger. Revision-2 machine snapshots
retain boot/counter/cadence/accounting and terminal fault state, with explicit defaults for legacy
revision-1 machines. Fault retries are rejected before any per-frame device reset. Current snapshots
are completed-frame or fault boundaries; they do not claim resumable source-statement execution.
Writable audio MMIO uses side-effect-free preparation and a commit after all bus targets validate.
It updates the existing voice/tracker objects directly; their existing synth snapshot remains the
single retained representation. Scanout and audio mixing run inside the scheduler's output phase
before its frame counter advances, so a device failure is captured by the same terminal fault latch.

Architecture decisions live in [`docs/adr`](adr/). The product brief remains authoritative when a
documented implementation detail conflicts with this overview.
