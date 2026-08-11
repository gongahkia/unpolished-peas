# Build and runtime evidence matrix

This matrix maps the separately configured CI checks and recorded local runtime
results. A configured job is not a completed runtime certification. The current
examples use the transitional Ebitengine adapter described in
[PUBLIC_API.md](PUBLIC_API.md); the production WebGPU baseline remains **no
desktop or browser host/renderer** under [ADR 0002](adr/0002-webgpu-dependency-decision.md).

| Target | CI evidence | Runtime evidence | Current classification |
| --- | --- | --- | --- |
| Linux amd64 | Configured Linux job runs formatting, vet, root tests, race tests, and both wasm example builds. | The isolated native WebGPU spike has one Vulkan first-frame and controlled-shutdown observation on Fedora 43; it is not an engine host. | Unit/build configured; isolated experiment has limited runtime evidence. |
| Windows amd64 | Configured native Windows job runs vet, root tests, and both example builds on a Windows runner. | No engine-owned graphical host/renderer run is recorded. | Unit/build configured; presentation unverified. |
| macOS | Configured native macOS job runs vet, root tests, and both example builds on a macOS runner. | No engine-owned graphical host/renderer run is recorded. | Unit/build configured; presentation unverified. |
| `GOOS=js GOARCH=wasm` | Configured wasm job builds Wukong and first-game bundles. The configured browser-smoke job fetches first-game wasm in Chromium and checks that the page does not report a startup exception. | The smoke does not exercise gameplay input, a rendered frame, resize, hidden tabs, or WebGPU. | Bundle/browser-load configured; renderer behavior unverified. |

Each job has a distinct check name. Native build outputs, wasm bundles, and
Playwright failure artifacts (trace and screenshot when produced) are
configured for upload by CI. A failed job should be classified as build, unit,
browser bundle-load, or runtime/presentation evidence rather than being
collapsed into a generic platform failure.

When adding a platform claim, first update this matrix with the exact command,
artifact, and whether the result ran on real hardware. The manual GPU matrix
and performance reporting rules are in [PERFORMANCE.md](PERFORMANCE.md); host
and renderer lifecycle requirements are in [BACKEND_DEVELOPMENT.md](BACKEND_DEVELOPMENT.md).
