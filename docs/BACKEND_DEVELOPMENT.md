# Host and renderer development

This guide is for contributors implementing an engine-owned platform host,
renderer, or test backend. Read [ARCHITECTURE.md](ARCHITECTURE.md),
[HOSTS.md](HOSTS.md), [INPUT.md](INPUT.md), and
[ADR 0003](adr/0003-engine-owned-webgpu-renderer.md) before changing a boundary.

## Current status

`engine/platform` owns the Linux X11 and browser hosts. `engine/render/webgpu`
uses the root-module pinned low-level WebGPU binding behind the portable
`engine/render` command boundary. It is not a public graphics-binding API.

The Linux path has local host-creation, deterministic software-WebGPU image,
and five-second example startup evidence. A local Chromium run has rendered,
accepted input, and resized the browser host. Windows/macOS native hosts and
browser behavior beyond that Chromium environment remain unverified; do not
turn source-target builds into support claims.

## Implementing a host

1. Implement `engine.Host`: provide a valid `HostContext` before
   `Application.Initialize`, then own `Run` on one event-loop goroutine.
2. Keep window/canvas creation, callbacks, resize/DPI conversion, visibility,
   clipboard, cursor, close policy, and native handles inside the host.
3. Convert callbacks to `engine.Event` only. Use logical pixels for pointer
   position and wheel data, report focus loss explicitly, and call
   `Runtime.SampleInput` for each batch. Do not pass platform key codes,
   physical pixels, or raw gamepad objects to a game.
4. Invoke runtime update, fixed update when the host owns a fixed accumulator,
   draw, and presentation from the same owner goroutine. Do not retain or use
   a `HostContext` after `Run` ends.
5. Return contextual unsupported-operation errors for unavailable window or
   clipboard features. Do not silently emulate an operating-system operation
   in runtime state.

A concrete host needs focused tests for callback conversion, lifecycle,
focus-loss releases, DPI/resize, and its platform-specific shutdown behavior.
A deterministic fake host can test the portable contract without importing a
windowing library.

## Implementing a renderer or test backend

1. Consume only `engine/render.Frame`, including the ordered queue, each
   command's effective screen-space `Clip()` result, and portable
   `TextureStore`. Native image/device/surface objects remain private.
2. Preserve submission order, world versus screen space, camera semantics, and
   texture ownership. Renderer cache entries are released and recreated only by
   renderer-owned lifecycle code; regular textures and glyph pages must
   rehydrate from portable sources after device loss, while render targets must
   be redrawn by the application.
3. Keep device creation, surface acquire/configure/present, GPU submission,
   and deferred destruction on the host render thread. A host may coordinate a
   frame but must not take ownership of renderer GPU state.
4. Use contextual errors for renderer failures; include the operation and
   retain the underlying cause where one exists. Unsupported WebGPU must be an
   explicit error, never a silent Canvas or WebGL fallback.
5. Cover command behavior with a headless/fake backend and image or command
   regressions before relying on a physical GPU. Runtime-tested platform
   coverage must be reported separately from compile-only coverage.

The initial renderer’s shader language is WGSL, and shader validation errors
need the operation, shader asset, and backend cause. Color conversion, blend
mode, sampling, DPI policy, resize, surface/device loss, and shutdown are
feature requirements, not implicit behavior inherited from another renderer.

`engine/render/internal/shader` owns the embedded, versioned WGSL catalog and
device-local pipeline-cache identity. A private adapter must validate each
asset through its actual WGSL compiler, then create the binding-specific native
pipeline from the provided descriptor. The cache preserves contextual validation
and creation failures and canonicalizes finite `render.Material` parameters;
read [RENDER_POLICY.md](RENDER_POLICY.md) before changing alpha, blend, or
sampling behavior.

`engine/render/internal/presentation` supplies the private lifecycle behavior
matrix for a chosen renderer. Its driver adapter maps native adapter/device,
surface configure, acquire, present, and release results into normalized faults
without leaking a binding type. The policy skips a timeout, suspends zero-sized
surfaces, reconfigures an outdated or lost surface, recreates a lost device,
and returns a terminal structured failure for out-of-memory or unclassified
faults. The WebGPU renderer maps the binding's sentinel errors to those same
outcomes on its render thread, while retaining the acquired texture needed
between encoding and present. Its scripted-driver and software-recreation
tests are not evidence of driver-initiated lifecycle behavior on a real target.

## Review boundary

Changing an exported `engine` or `engine/render` type requires the public API
review in [PUBLIC_API.md](PUBLIC_API.md). A new platform binding, shader model,
native artifact process, or ownership change requires an ADR before its
implementation becomes the project direction. Keep binding imports below the
private renderer seam; tests and examples must not normalize a binding type as
part of the public API.

For the binding decision and remaining evidence limits, see
[ADR 0003](adr/0003-engine-owned-webgpu-renderer.md).
