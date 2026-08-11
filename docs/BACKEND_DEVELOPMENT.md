# Host and renderer development

This guide is for contributors implementing an engine-owned platform host,
renderer, or test backend. Read [ARCHITECTURE.md](ARCHITECTURE.md),
[HOSTS.md](HOSTS.md), [INPUT.md](INPUT.md), and
[ADR 0001](adr/0001-webgpu-renderer-boundary.md) before changing a boundary.

## Current status

There is no engine-owned native host, browser host, or production WebGPU
renderer. `engine/ebiten` is a transitional compatibility adapter. It is not a
template for leaking Ebitengine types into public APIs. It translates its
available keyboard, pointer, committed-text, and gamepad state into portable
events, but supplies no `HostContext` and is not platform parity.

No production graphics dependency may be added to the root module while
[ADR 0002](adr/0002-webgpu-dependency-decision.md) remains accepted. Use the
nested WebGPU experiments to gather the promotion evidence instead. An
experiment is isolated precisely so its dependencies cannot become a default
engine build or public API by accident.

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
   texture ownership. Renderer cache entries are recreated after device loss
   and released only by renderer-owned lifecycle code.
3. Keep device creation, surface acquire/configure/present, GPU submission,
   and deferred destruction on the host render thread. A host may coordinate a
   frame but must not take ownership of renderer GPU state.
4. Use contextual errors for renderer failures; include the operation and
   retain the underlying cause where one exists. Unsupported WebGPU must be an
   explicit error, never a silent Ebitengine or WebGL fallback.
5. Cover command behavior with a headless/fake backend and image or command
   regressions before relying on a physical GPU. Runtime-tested platform
   coverage must be reported separately from compile-only coverage.

The initial renderer’s shader language is WGSL, and shader validation errors
need the operation, shader asset, and backend cause. Color conversion, blend
mode, sampling, DPI policy, resize, surface/device loss, and shutdown are
feature requirements, not implicit behavior inherited from Ebitengine.

`engine/render/internal/presentation` supplies the private lifecycle policy a
chosen renderer must use on its render thread. Its driver adapter maps native
adapter/device, surface configure, acquire, present, and release results into
the package's normalized faults without leaking a binding type. The policy
skips a timeout, suspends zero-sized surfaces, reconfigures an outdated or lost
surface, recreates a lost device, and returns a terminal structured failure for
out-of-memory or unclassified faults. Its scripted-driver tests are faithful
policy tests, not evidence of a real platform implementation; a selected
binding still needs runtime lifecycle coverage.

## Review boundary

Changing an exported `engine` or `engine/render` type requires the public API
review in [PUBLIC_API.md](PUBLIC_API.md). A new platform binding, shader model,
native artifact process, or ownership change requires an ADR before its
implementation becomes the project direction. Keep binding imports below the
private renderer seam; tests and examples must not normalize a binding type as
part of the public API.

For the evidence and decision process, see [ADR 0002](adr/0002-webgpu-dependency-decision.md).
