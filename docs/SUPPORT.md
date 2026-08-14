# Build and runtime evidence matrix

This matrix maps recorded local evidence and the versioned CI configuration. A
configured job is not a completed runtime certification. GitHub Actions is
currently unavailable, so no current CI result is claimed. The examples use
`engine/platform` and the engine-owned renderer described in
[ADR 0003](adr/0003-engine-owned-webgpu-renderer.md).

| Target | CI evidence | Runtime evidence | Current classification |
| --- | --- | --- | --- |
| Linux amd64 | Local formatting, vet, root tests, race tests, and example builds are required; current CI execution is unavailable. | `TestX11HostCreatesNativeWindow` creates/maps an X11 window and initializes the renderer. `TestHeadlessRendererProducesOrderedSpriteAndTilePixels` checks deterministic software-WebGPU output; `TestHeadlessRendererSupportsLinearSamplingAndAdditiveBlend` checks typed renderer options on the forced fallback adapter; `TestHeadlessRendererRecreatesItsDeviceAndRehydratesPortableTextures` checks local recovery. `bin/first-game` stayed alive for five seconds on Fedora 43 under the X11/WebGPU host. evdev gamepad logic has unit coverage but no physical-controller result. | Local host/startup and software-renderer evidence; physical presentation image, controller behavior, driver-initiated loss, and broader hardware coverage unverified. `72_PHYSICAL_GPU=1 go test ./engine/render/webgpu -run TestPhysicalGPU` is an opt-in non-fallback adapter check, not a presentation certification. |
| Windows amd64 | `GOOS=windows GOARCH=amd64 go test -c` compiles the Win32 host and private WebGPU surface; current CI execution is unavailable. | Native source implements window creation, message polling, DPI/resize, focus, close, cursor, Unicode clipboard, IMM composition, and optional XInput paths. None has run on Windows hardware. | Build-only target; runtime/presentation and input-adapter behavior unavailable. |
| macOS arm64/amd64 | `GOOS=darwin GOARCH=arm64` and `GOOS=darwin GOARCH=amd64` compile the AppKit/CAMetalLayer host and private WebGPU surface; current CI execution is unavailable. | Native source implements AppKit event polling, backing-scale resize, focus, close, cursor, clipboard, and optional GameController polling, but none has run on macOS hardware. Composition is explicitly unavailable. | Build-only target; runtime/presentation and GameController behavior unavailable. |
| `GOOS=js GOARCH=wasm` | Local wasm bundles can be built; current CI execution is unavailable. | Chromium loaded first-game from a local HTTP origin, rendered the WebGPU scene, accepted ArrowRight input, resized the canvas, and exercised focus/hidden-tab behavior without page errors. The audio WASM smoke checks post-gesture startup and expected play/gain/stop status transitions, but it does not prove sound reached an output device. Browser Gamepad and composition code compile but lack focused runtime assertions. | Local Chromium runtime evidence; audible browser audio, Gamepad/IME behavior, device loss, Firefox, Safari, and real high-DPI hardware remain unverified. |

When CI access is restored, classify each result as build, unit, browser
bundle-load, or runtime/presentation evidence rather than collapsing it into a
generic platform failure.

When adding a platform claim, first update this matrix with the exact command,
artifact, and whether the result ran on real hardware. The manual GPU matrix
and performance reporting rules are in [PERFORMANCE.md](PERFORMANCE.md); host
and renderer lifecycle requirements are in [BACKEND_DEVELOPMENT.md](BACKEND_DEVELOPMENT.md).

## Local diagnostic bundles

`72 doctor -out 72-support.zip` records the current Go version, target, and a
best-effort WebGPU availability probe. On native targets that probe uses the
headless fallback adapter, so `available` means only that the local binding
could initialize it. The report always labels certification as `unverified`;
it cannot upgrade a target from buildable to runtime-certified. The ZIP
contains the JSON report, a restricted Go environment summary, and this
limitation in text form.
