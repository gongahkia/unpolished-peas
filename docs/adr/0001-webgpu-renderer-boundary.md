# ADR 0001: keep rendering WebGPU-shaped and backend-private

**Status:** accepted

**Date:** 2026-08-11

## Context

72 currently exposes a backend-neutral runtime and the `engine/render` command
contract, but a temporary framework adapter still owns windowing, input
sampling, Canvas compatibility drawing, and command translation.
That adapter is intentionally temporary. A replacement needs to serve native
Linux, Windows, and macOS applications and `GOOS=js GOARCH=wasm` without
exposing a graphics binding in a game's public API.

The engine needs an architectural decision before exploratory renderer work
adds a binding, shader format, or host contract that would be expensive to
unwind.

## Decision

72 adopts WebGPU concepts and WGSL as the engine-owned renderer boundary. This
is an architecture decision, not a decision to add a WebGPU dependency yet.

- `engine/render` remains the only application-facing rendering API. Its
  textures, command payloads, cameras, and eventual render-target handles are
  portable engine values; they must not contain a WebGPU, windowing, or
  platform-native handle.
- A future private renderer package owns adapters, devices, surfaces, queues,
  GPU resources, shader compilation, pipeline caches, and deferred disposal.
  It translates `engine/render.Frame` into backend calls. Only this private
  layer may import a chosen WebGPU binding.
- A future platform host owns window/canvas creation, event polling, size/DPI,
  clipboard, cursor, and lifecycle. It passes an opaque native-surface target
  to the private renderer; the renderer does not create a window or sample game
  input.
- GPU device creation, surface acquire/configure/present, and command
  submission are confined to the host's render thread. Resource destruction is
  queued to that thread. Public game code never receives a device, queue, or
  native surface.
- WGSL is the only engine shader source language. Engine-provided shaders are
  embedded and versioned with the renderer. Shader validation failures must
  identify the operation, shader asset, and backend cause; user-authored
  shaders are outside the current milestone.
- The renderer starts with explicit non-premultiplied RGBA input and documents
  conversion at the backend boundary. Blend mode, color-space, sampling, and
  DPI policy are specified alongside the relevant renderer features rather
  than inherited accidentally from another renderer.
- The renderer is responsible for recovering from resize and recoverable
  surface loss, and for returning contextual errors for terminal device or
  out-of-memory failures. The detailed public error model is deferred to the
  structured-errors work item.

## Candidate bindings and evaluation

No candidate is imported by this ADR. The native and browser spikes will test
the following candidates before the dependency decision:

| Candidate | Why it is evaluated | Material concern to resolve |
| --- | --- | --- |
| `github.com/go-webgpu/webgpu` over `wgpu-native` | Current Go binding with Windows, Linux, and macOS surface support; it uses a downloadable native `wgpu-native` library. | Distribution, ABI/version pinning, device-loss behavior, and whether its native dependency works with the desired host layer. |
| `github.com/gogpu/wgpu` | A single Go API advertises native backends and a browser-WASM implementation. | It is a newer implementation with a large backend surface; the spikes must establish API stability, validation behavior, and release/support viability. |
| Direct `wgpu-native` C API wrapper | The upstream native implementation has release binaries for the three desktop platforms. | Owning a new low-level binding would add substantial maintenance, ABI, callback, and safety work. It is a fallback, not the preferred initial path. |
| Browser WebGPU through `syscall/js` | Browsers expose WebGPU through JavaScript, independently of a native binding. | The browser spike must prove canvas ownership, resize/DPI handling, async adapter/device errors, visibility handling, and a graceful no-WebGPU path. |

The dependency decision in the follow-up ADR must compare candidates against
these required criteria:

1. A minimal triangle/surface prototype builds and runs on Linux, Windows, and
   macOS, and a wasm prototype presents through browser WebGPU.
2. The API supports deterministic handling of resize, surface loss, device
   loss, timeout, and shutdown, with errors that retain an underlying cause.
3. The published artifacts and licenses permit reproducible redistribution for
   supported architectures, including a documented security-update process.
4. The binding can be pinned in `go.mod` (and any native artifact manifest),
   and its release cadence, ownership, and compatibility commitments are
   acceptable for an engine dependency.
5. The implementation permits a headless/fake backend for command and image
   regression tests without requiring a physical GPU.
6. The design can maintain stable submission order, world/screen-space camera
   semantics, texture lifetime, and explicit resource ownership without
   leaking binding types through exported packages.

`wgpu-native` is a native implementation and does not provide browser WebGPU
for Go wasm by itself. Browser presentation therefore remains a separately
validated host path even if the native decision selects a wgpu-native binding.
WebGPU also requires a secure browser context and is not a universal browser
baseline; the browser host must expose an actionable unsupported-feature error
rather than silently falling back to a framework renderer or WebGL.

## Package and ownership shape

The intended dependency direction is:

```text
game -> engine, engine/render
engine -> engine/ecs, engine/render
private host -> engine
private renderer -> engine/render, chosen WebGPU binding
private host -> private renderer
```

The private host may coordinate a frame, but it cannot give game code native
window or GPU objects. The renderer may cache native representations of
portable `render.Texture` data, but cache entries are invalidated when the
device is recreated and are released only by renderer-owned lifecycle code.

## Legacy-adapter retirement criteria

The legacy framework adapter and Canvas remain supported only until the engine-owned
host and renderer demonstrate Wukong parity. Removal requires all of the
following evidence:

- native and wasm Wukong builds run through engine-owned hosts with no
  framework-renderer imports in the engine or example;
- command-frame support covers Wukong's sprites, tile maps, primitives, and
  text while preserving documented stable ordering and coordinate semantics;
- a headless reference backend and image regressions cover those command types;
- resize, focus loss, surface/device loss, and clean shutdown have automated
  tests or a documented manual matrix on each supported target;
- CI compiles every claimed target and distinguishes build-only from
  runtime-tested coverage; and
- public documentation and the quickstart use command frames exclusively.

## Consequences

The next work is deliberately split: native and browser spikes validate the
candidate paths; a later ADR selects a concrete dependency and distribution
strategy; platform and renderer implementations then grow behind the private
boundary. This avoids committing 72's exported API to a binding before its
platform, packaging, and failure behavior are evidenced.

The decision adds documentation only. It does not add a GPU dependency, change
the current framework adapter, claim browser support, or remove the Canvas
compatibility path.

## Implementation update

On 2026-08-12, the command-frame migration retired the legacy `engine.Canvas`
and immediate `Layer.Draw` API. `Runtime.Draw` now consumes a
`render.Backend` directly, so supported examples and the transitional framework
adapter use only `render.Frame`. This historic update did not satisfy the
separate adapter-retirement criteria at that time.

## Sources checked on 2026-08-11

- [W3C WebGPU specification](https://www.w3.org/TR/webgpu/)
- [W3C WebGPU Shading Language specification](https://www.w3.org/TR/WGSL/)
- [go-webgpu package documentation](https://pkg.go.dev/github.com/go-webgpu/webgpu)
- [gogpu/wgpu repository](https://github.com/gogpu/wgpu)
- [wgpu-native repository](https://github.com/gfx-rs/wgpu-native)
- [MDN WebGPU API compatibility and secure-context notes](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API)
