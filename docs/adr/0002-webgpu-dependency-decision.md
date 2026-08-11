# ADR 0002: defer the production WebGPU dependency

**Status:** accepted

**Date:** 2026-08-11

## Context

[ADR 0001](0001-webgpu-renderer-boundary.md) chose a WebGPU-shaped private
renderer boundary and WGSL, but explicitly did not select a production binding.
The required native and browser experiments now exist in
`experiments/webgpu-native` and `experiments/webgpu-browser`.

The decision must account for a binding's API, the window/surface layer,
browser presentation, distribution and license obligations, supported targets,
and observable failure behavior. A package compiling is useful evidence, but is
not equivalent to a working surface on a driver, compositor, or browser.

## Evidence reviewed

| Candidate / path | Evidence | Material gap |
| --- | --- | --- |
| `github.com/gogpu/gogpu v0.52.1` with `github.com/gogpu/wgpu v0.31.2` | The isolated native spike compiled for Linux amd64, Windows amd64, and macOS arm64. On this Fedora 43 Linux host it selected Intel Iris Xe through Vulkan, made a surface in 63 ms, and presented its first frame in 64 ms. A subsequent five-second X11 smoke sustained 306 frames over 5.048 s, accepted a resize callback, and shut down cleanly; the corresponding Wayland smoke sustained 293 frames over 5.006 s but emitted an unresolved callback-teardown warning. A fresh 2026-08-12 Wayland repeat again emitted that warning after 294 frames over 5.011 s. | Only one Linux GPU/compositor pair was run for each window system. Windows and macOS are compile-only. The smoke verifies controlled, not user-initiated, shutdown and does not verify device loss. The exact pinned release also has an open [Wayland fractional-scaling deadlock report](https://github.com/gogpu/gogpu/issues/448), which this repository did not reproduce. Its documented support is pre-v1 and Linux/macOS remain community-tested. |
| Browser WebGPU through `syscall/js` | The isolated wasm spike compiles, owns/configures a canvas, handles device-pixel resize and hidden documents, and reports `GPUDevice.lost`. Chromium automation verified the no-adapter message without a panic. A headed Playwright Chromium 152.0.7977.8 run with unsafe WebGPU/Vulkan flags rendered a stable clear pass, reconfigured a `1200x854` DPR-1 canvas after resize, verified a `2048x1444` canvas for a DPR-2-emulated `1024x722` CSS box, and reported a controlled `GPUDevice.destroy()` loss with no page errors. | This is one flag-enabled Chromium/Linux observation; the DPR result is emulation, not a physical-display test. It is not default-browser or driver-loss evidence. Firefox and Safari have no runtime result; hidden-tab and real device-loss recovery remain unverified. |
| `github.com/go-webgpu/webgpu v0.5.5` with `wgpu-native v29` | Current package documentation exposes desktop surfaces, error scopes, and a versioned native-library setup. `wgpu-native` publishes Linux, Windows, and macOS binaries under Apache-2.0 or MIT. | It still needs a separate native window layer and a bundled/shared-library distribution, checksum, ABI, and security-update policy. It has no browser-WASM implementation. |
| Direct `wgpu-native` wrapper | Upstream publishes native binaries and C bindings for desktop targets. | 72 would own ABI bindings, native callback safety, surface plumbing, and every artifact update; this is more maintenance than the other candidates without adding browser coverage. |

The experiment reports contain commands, exact module versions, target-build
results, runtime caveats, and source links. They are the evidence record; this
ADR does not upgrade an observed single-machine result into a support claim.

## Decision

72 rejects selecting or adding a production WebGPU binding at this time. The
root module retains no GoGPU, go-webgpu, or wgpu-native dependency. Both spikes
remain isolated nested modules so their dependencies cannot leak into the
engine's exported API or default builds.

The engine-owned WebGPU renderer and host support baseline is therefore **no
production desktop or browser target**. The temporary Ebitengine adapter keeps
its existing separate support boundary; its presence is not a WebGPU fallback.
Linux amd64 has one experimental first-frame observation only. Windows amd64,
macOS arm64, Chromium, Firefox, and Safari are experimental compile or
feature-detection targets only, not supported runtime platforms.

This is a rejection based on insufficient cross-platform runtime evidence, not
a rejection of WebGPU as the architecture boundary. `engine/render` stays
backend-neutral, WGSL remains the intended private shader language, and
`engine/ebiten` remains the temporary compatibility adapter under ADR 0001's
retirement criteria.

## Replacement experiment and promotion gate

Before reopening the dependency decision, run the two existing spikes on real
hardware and record the following in a reviewable compatibility report:

1. Linux X11 and Wayland, Windows, and macOS: adapter/backend, GPU/driver,
   initial surface, first frame, repeated resize, user-initiated clean
   shutdown, and an induced surface/device-loss result.
2. A current WebGPU-capable Chromium, Firefox, and Safari configuration:
   secure-context feature detection, first clear pass, DPI resize, hidden-tab
   behavior, and `GPUDevice.lost` or equivalent recovery/error behavior.
3. Artifact ownership: exact Go module and native-library versions, supported
   architectures, license notices, release signature/checksum verification,
   a reproducible vendoring/download process, and a security-update owner.
4. A chosen host integration that preserves ADR 0001 ownership: the host owns
   a native surface and event loop, the private renderer owns device/surface
   lifecycle, and no chosen-library type reaches `engine` or `engine/render`.

An approved follow-up ADR must pin one dependency and distribution method only
after this gate has evidence for the initial support matrix. It must specify
fallback behavior: unsupported WebGPU returns a contextual error; it must not
silently select Ebitengine or WebGL.

## Consequences

Platform-host and renderer production issues remain blocked on the promotion
gate. The work that is safe now is backend-neutral contracts, deterministic
reference rendering, assets, diagnostics, documentation, and isolated
experiments. This costs schedule time, but avoids distributing an unvalidated
native binary or claiming browser support that has not presented a frame.

## Sources checked on 2026-08-11

- [native spike and compatibility record](../../experiments/webgpu-native/README.md)
- [browser spike and compatibility record](../../experiments/webgpu-browser/README.md)
- [GoGPU `v0.52.1` release](https://github.com/gogpu/gogpu/releases/tag/v0.52.1)
- [go-webgpu `v0.5.5` documentation](https://pkg.go.dev/github.com/go-webgpu/webgpu@v0.5.5)
- [wgpu-native `v29.0.0.0` release](https://github.com/gfx-rs/wgpu-native/releases/tag/v29.0.0.0)
- [MDN WebGPU API compatibility and secure-context notes](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API)
