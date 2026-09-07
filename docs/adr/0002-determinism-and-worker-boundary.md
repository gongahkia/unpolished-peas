# ADR 0002: Determinism and worker boundary

- Status: accepted
- Date: 2026-09-07

## Decision

Generated cartridge JavaScript executes in a dedicated disposable module worker. The worker receives
only validated input frames and console API messages. Cartridge time, RNG, task scheduling, work
accounting, save access, and replay events are console-owned deterministic state. Network, DOM,
dynamic code construction, arbitrary imports, and ambient time are unavailable to PXCL programs.

Compile deterministic work checks at function entries, loop back-edges, task transitions, bounded
capacity operations, and expensive console calls. Treat browser worker termination as the final
host-side guard for code that cannot return to an inserted check.

## Reasoning

Language-level capability denial is stronger and easier to audit than attempting to make arbitrary
JavaScript safe. A disposable worker keeps runaway or corrupted cartridges from blocking the studio.
Explicit deterministic state is also the basis for replay, rewind, and debug/release equivalence.

## Consequences

The sandbox is a practical capability boundary, not a claim of origin isolation. Worker protocol
validation and CSP remain required. Runtime snapshots must serialize all observable console state.
Security documentation must state the browser-process limits honestly.
