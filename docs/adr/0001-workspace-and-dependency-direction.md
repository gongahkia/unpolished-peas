# ADR 0001: Workspace and dependency direction

- Status: accepted
- Date: 2026-09-07

## Decision

Use a Cargo workspace for compiler-owned behavior and a pnpm workspace for browser-owned behavior.
Keep `pxcl-core` free of browser APIs. Expose it to the studio through a small `wasm-bindgen` crate
and to external editors through the native CLI. Keep hardware coordination in a framework-light
TypeScript package and use Vite only as the static build shell.

## Reasoning

The compiler, formatter, packer, and analysis must have identical semantics in browser and native
workflows. A portable Rust core gives one authoritative implementation and supports high-coverage
host tests. A narrow WASM bridge makes serialization and capability boundaries inspectable. Vite is
sufficient for a static offline application and avoids imposing a server architecture.

## Consequences

Cross-boundary data must be serializable and versioned. The studio cannot patch compiler semantics.
The runtime can be tested without rendering host chrome. WASM packaging is an explicit build step.
