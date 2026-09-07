# Security boundaries

PX-240C cartridges are untrusted inputs, but the alpha is not a claim of process-level isolation.
The practical boundary combines a restricted source language, compiler-owned generation, a
disposable Web Worker, a validated message protocol, deterministic budgets, and browser origin
controls.

## Cartridge capabilities

PXCL/1 has no syntax for raw JavaScript, host values, dynamic code, ambient globals, arbitrary
imports, DOM access, network access, wall-clock time, or host persistence. Named console operations
lower to a fixed dispatcher. Unknown calls fail at the nearest runtime boundary.

Generated JavaScript runs in a dedicated module worker. Before evaluating it, the worker removes or
shadows `Date`, network constructors, browser storage, `crypto`, `navigator`, `eval`, `Function`, and
`Math.random` where the browser permits those properties to be replaced. Cartridge module URLs must
use the host-created `blob:` scheme. Messages in both directions are structurally validated.

The worker receives cloned input frames, its own validated integer save-value copy, and bounded map
query data, then returns draw/audio commands and sorted save writes. It does not receive IndexedDB
handles, the studio project database, another cartridge ID, or another cartridge's save block. The
trusted host applies writes through a capability bound to the immutable current cartridge ID and
enforces the 8 KiB limit.

## Resource controls

The compiler charges synthetic work units at function entries, loop back-edges, task transitions,
integer/capacity operations, allocations, and console calls. Exceeding the per-frame limit throws a
source-spanned `PX9001` fault. Tasks are explicit serializable program-counter machines and do not
receive promises. The host also applies a response deadline and terminates a worker that stops
responding, covering malformed or non-compiler JavaScript that never reaches an inserted check.

These controls protect studio responsiveness and deterministic replay semantics. They do not defend
against a compromised browser engine, same-origin side channels outside the worker model, or a user
manually substituting arbitrary JavaScript for compiler output.

Standalone HTML exports embed the canonical decoded cartridge and a smaller dependency-free player.
Their worker accepts only compiler-produced build output from that embedded cartridge, applies the
same 50,000-unit and 4,096-command ceilings, and has no project-database capability. The standalone
file is intentionally self-contained and therefore uses inline script and `blob:` module workers;
it does not claim the same deployable Content Security Policy surface as the hashed Studio build. A
user who edits the exported HTML can also edit its runtime and must not treat it as a signed format.

The PWA service worker caches only same-origin GET requests and an exact build-generated inventory.
Its cache revision covers hashed bundles and bundled-cartridge bytes. It adds offline availability,
not a new cartridge capability or a trust boundary.

## Verified evidence

On 2026-09-07, the production Vite worker bundle was exercised in Firefox 155 through Playwright:

- compiler-produced code completed a frame and returned one validated draw command;
- the worker audit found none of the denied globals exposed and no `Math.random`;
- an infinite PXCL `while true` loop stopped with source-spanned `PX9001` while the page remained
  responsive;
- the display remained unclipped and crisp at exact 2x and 3x viewports.

The query routes `?sandbox-test=normal`, `?sandbox-test=capabilities`, and
`?sandbox-test=runaway` reproduce those checks after `pnpm dev`.
