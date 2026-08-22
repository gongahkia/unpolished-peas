# ADR 0003: select the low-level WebGPU binding for the engine-owned renderer

**Status:** accepted

**Date:** 2026-08-12

**Supersedes:** [ADR 0002](0002-webgpu-dependency-decision.md)

## Context

ADR 0002 deferred a production graphics binding because the available runtime
matrix was too small to make a support claim. The engine still depended on the
temporary framework adapter, which made the transition impossible to
complete. The project owner has now explicitly directed 72 to remove
the legacy framework renderer and replace it with an engine-owned graphics renderer.

That instruction changes the decision: the remaining uncertainty constrains
the support matrix and verification claims; it does not justify retaining the
temporary engine. The replacement must keep every driver, window, and browser
object out of `engine` and `engine/render` public APIs.

## Decision

72 selects `github.com/gogpu/wgpu v0.31.2` as a **private, low-level WebGPU
binding**. The root module pins it directly. The default native path is its
pure-Go implementation; `-tags rust` is not a supported 72 build mode and 72
does not distribute `wgpu-native` binaries. For `GOOS=js GOARCH=wasm`, the
same public package uses the browser WebGPU API through `syscall/js`.

This is a binding decision, not a renderer-framework decision:

- `engine/render` remains the public, backend-neutral command contract.
- 72 owns the renderer that translates complete command frames into WebGPU
  buffers, textures, bind groups, pipelines, command encoders, and presents.
  It owns ordered batching, cache invalidation, explicit release, and every
  binding-specific type.
- 72 owns native window and browser canvas hosts. A host supplies an opaque
  surface target, portable events, clock, DPI, and lifecycle state. The
  renderer neither creates a window nor samples application input.
- WGSL assets remain embedded and versioned. Device-level shader module and
  pipeline creation are the production validation path; the existing
  binding-neutral pipeline cache remains the policy/identity layer.
- Unsupported WebGPU, adapter/device creation, or platform-host capability
  returns a contextual error. There is no framework, Canvas, or WebGL
  fallback.
- Native default builds blank-import the binding's platform backend registrar
  inside the private renderer. Application packages do not select a driver.

The binding is MIT licensed and requires Go 1.25, which matches this module's
existing Go version. Its transitive modules are implementation dependencies,
not application-facing APIs. Their licenses and security updates are reviewed
when the pinned binding version changes.

## Support and evidence boundary

Selecting a binding does not make every advertised binding target a supported
72 runtime. Current evidence is intentionally narrower:

| Target | Current claim | Evidence still required before support is claimed |
| --- | --- | --- |
| Linux amd64 | implementation and local runtime verification target | X11 and Wayland manual matrix, including user close and device-loss recovery |
| Windows amd64 | compile target | real hardware/window/manual lifecycle matrix |
| macOS arm64 | compile target | real hardware/window/manual lifecycle matrix |
| Browser wasm | implementation and local Chromium runtime verification target | Firefox and Safari secure-context/manual lifecycle matrix, plus device-loss and hidden-tab coverage |

The browser requires a secure context with WebGPU enabled. The host must
report the unavailable feature instead of presenting a degraded renderer.
GitHub Actions is currently unavailable to this project, so local focused
tests and target builds are the required verification for this change; remote
CI evidence remains unavailable rather than inferred.

## Consequences

The temporary framework adapter and its root-module dependency are retired
only after examples use the engine-owned host and renderer. The remaining
issues are implementation work, not a dependency-decision blocker. Their
acceptance conditions still require actual renderer/host behavior and must not
be closed on compile-only evidence.

The renderer has a deliberately narrow first milestone: ordered 2D textured
quads, tile quads, solid primitives represented by a private white texture,
glyph-atlas quads, nearest sampling, source-over blending, surface
reconfiguration, and explicit resource release. Advanced materials, user WGSL,
MSAA, linear sampling, and a WebGL fallback remain out of scope.

## Sources checked on 2026-08-12

- [gogpu/wgpu v0.31.2 source and module metadata](https://github.com/gogpu/wgpu/tree/v0.31.2)
- [gogpu/wgpu surface target contract](https://github.com/gogpu/wgpu/blob/v0.31.2/surface_target.go)
- [WebGPU specification](https://www.w3.org/TR/webgpu/)
- [WGSL specification](https://www.w3.org/TR/WGSL/)
