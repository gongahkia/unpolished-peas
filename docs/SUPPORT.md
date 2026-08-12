# Build and runtime evidence matrix

This matrix maps recorded local evidence and the versioned CI configuration. A
configured job is not a completed runtime certification. GitHub Actions is
currently unavailable, so no current CI result is claimed. The examples use
`engine/platform` and the engine-owned renderer described in
[ADR 0003](adr/0003-engine-owned-webgpu-renderer.md).

| Target | CI evidence | Runtime evidence | Current classification |
| --- | --- | --- | --- |
| Linux amd64 | Local formatting, vet, root tests, race tests, and example builds are required; current CI execution is unavailable. | `TestX11HostCreatesNativeWindow` creates/maps an X11 window and initializes the renderer. `TestHeadlessRendererProducesOrderedSpriteAndTilePixels` checks deterministic software-WebGPU output; `TestHeadlessRendererRecreatesItsDeviceAndRehydratesPortableTextures` checks local recovery. `bin/first-game` stayed alive for five seconds on Fedora 43 under the X11/WebGPU host. | Local host/startup and software-renderer evidence; physical presentation image, driver-initiated loss, and broader hardware coverage unverified. |
| Windows amd64 | Cross compilation is a local source-target check; current CI execution is unavailable. | No native host runtime is implemented or recorded. | Build-only target; presentation unavailable. |
| macOS | Cross compilation is a local source-target check; current CI execution is unavailable. | No native host runtime is implemented or recorded. | Build-only target; presentation unavailable. |
| `GOOS=js GOARCH=wasm` | Local wasm bundles can be built; current CI execution is unavailable. | Chromium loaded first-game from a local HTTP origin, rendered the WebGPU scene, accepted ArrowRight input, resized the canvas, and exercised focus/hidden-tab behavior without page errors. | Local Chromium runtime evidence; device loss, Firefox, Safari, and real high-DPI hardware remain unverified. |

When CI access is restored, classify each result as build, unit, browser
bundle-load, or runtime/presentation evidence rather than collapsing it into a
generic platform failure.

When adding a platform claim, first update this matrix with the exact command,
artifact, and whether the result ran on real hardware. The manual GPU matrix
and performance reporting rules are in [PERFORMANCE.md](PERFORMANCE.md); host
and renderer lifecycle requirements are in [BACKEND_DEVELOPMENT.md](BACKEND_DEVELOPMENT.md).
