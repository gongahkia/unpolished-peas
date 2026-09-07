# Architecture

PX-240C is a static browser application backed by one compiler and cartridge implementation shared
with a native Linux CLI.

## Package ownership

- `crates/pxcl-core`: PXCL syntax, semantic analysis, typed IR, code generation, debug metadata,
  deterministic cartridge encoding, formatter, and language-service analysis.
- `crates/pxcl-wasm`: a deliberately narrow WebAssembly boundary over `pxcl-core`.
- `crates/px240c-cli`: native command family and stdio language server, both using `pxcl-core`.
- `packages/runtime`: deterministic hardware model, worker protocol, indexed graphics, input, audio,
  persistence adapters, debugger, replay, and export support.
- `apps/studio`: 240x144 shell and integrated tools. It consumes the runtime and compiler bridge but
  owns neither compiler rules nor cartridge execution.

Dependencies point inward: studio -> runtime/WASM bridge -> compiler core. Cartridge code runs only
in a dedicated worker and communicates through a versioned, validated message protocol. It never
receives persistence handles or DOM objects.

## Data flow

PXCL source is tokenized, parsed, resolved to stable symbol IDs, type-checked against a typed asset
catalog, and lowered to a serializable structured IR. That IR is instrumented and generated as
compact JavaScript plus source maps; the same IR produces debug and release output.
Projects remain Git-friendly directories; packing creates a canonical, content-addressed `.pxc`
artifact containing original source and compiled output.

Debug output adds source probes and routine enter/leave hooks without changing typed IR. The worker
returns bounded traces and serializable state/task inspection only when debug mode is requested.
The Studio combines periodic worker snapshots with indexed-framebuffer and synthesizer snapshots;
recorded inputs and canonical fingerprints provide deterministic rewind with explicit divergence
detection. The debugger does not receive DOM, persistence, or network capabilities.

Architecture decisions live in [`docs/adr`](adr/). The product brief remains authoritative when a
documented implementation detail conflicts with this overview.
