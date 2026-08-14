# Engine readiness audit

This is an evidence-led assessment of the current worktree on
2026-08-14. It is not a release declaration. Scores measure readiness for a
maintained, general-purpose 2D game-engine runtime, where `10` means a
documented support matrix, repeatable release process, and target-specific
runtime evidence.

| Area | Score | Verified strengths | Release-blocking gaps |
| --- | --- | --- | --- |
| 2D renderer | 6/10 | Ordered, instanced sprites and tiles; reusable dynamic buffers; primitives, text, clips, WGSL validation, texture caches, deterministic software-WebGPU image regression, and local device recreation/rehydration. | No physical-GPU image regression, no real driver-loss matrix, nearest sampling only, and render targets must be redrawn after recreation. |
| Platform hosts | 4/10 | Linux X11 creation/startup and a local Chromium render/input/resize/focus/visibility result. [Source-verified] Hosts map common physical keys; browser uses composition events and the Gamepad API, Windows uses IMM and XInput when available, Linux uses evdev when accessible, and macOS polls GameController when the framework is present. | Windows/macOS have no runtime evidence; X11 clipboard and hidden cursor are unsupported because the public contract is synchronous; Linux/macOS composition remains unavailable pending XIM/NSTextInputClient integration, and gamepad/IME paths lack runtime evidence. |
| Runtime/gameplay APIs | 6/10 | Deterministic ECS scheduling, input normalization, reloadable assets, mixer state, AABB physics, scene transforms, and retained UI layout are tested. Non-finite viewport/camera/render inputs now fail at useful boundaries. | UI is a preview; physics is intentionally AABB-only; browser audio output and user-facing tooling have no runtime evidence. |
| Diagnostics and performance | 5/10 | Per-frame command, texture, pipeline, batch, draw, and duration metrics; bounded Chrome-compatible CPU traces; reproducible CPU reference and deterministic software-WebGPU tile benchmarks. | No GPU timestamps, physical-GPU benchmark/report, or automatic performance baseline comparison. |
| Test and build engineering | 5/10 | Local formatting, vet, unit/race tests, target builds, vulnerability scan, and a Chromium render/input/resize/focus/visibility smoke are available. | GitHub Actions cannot currently run; Windows/macOS checks are compile-only. |
| Product and release | 3/10 | Scope, support evidence, compatibility, and release gates are explicitly documented. | No selected `LICENSE`/`NOTICE`, no published artifacts, no completed remote CI for an exact commit, and no target certification or release owner approval. |

## Overall verdict: 4/10

72 is a credible pre-1.0, 2D-first engine runtime with an engine-owned graphics
path. It is not ready to be declared a generally supported game engine or to
ship a v0.1 release. The limiting factors are platform and release evidence,
not the existence of core engine packages.

## Improvements completed in this audit batch

- Replaced reachable non-finite render input paths with validation for sprites,
  tiles, primitives, text, viewport configuration, and camera submission.
- Corrected WebGPU primitive geometry to centre circle strokes on their declared
  radius, avoid overdraw when a rectangle stroke consumes its interior, and
  use round line caps consistent with the documented reference contract.
- Forced headless renderer tests through the binding's deterministic software
  adapter; added ordered sprite/tile pixel regression and device
  recreation/portable-texture rehydration coverage, plus texture refresh and
  release coverage.
- Converted compatible sprites, tile maps, and atlas text glyphs to instanced
  GPU draws, with a deterministic tile benchmark that reports visible tiles,
  submitted batches, and draw calls.
- Replaced per-batch GPU-buffer creation with renderer-owned grow-on-demand
  vertex and instance buffers, and exposed their capacity through diagnostics.
- Added bounded Chrome-compatible CPU traces for runtime updates, draws, and
  renderer submission without claiming asynchronous GPU timing.
- Added native-pipeline entry metrics and documented their limits.
- [Source-verified] Made browser host shutdown return the originating
  update/draw failure and remove event listeners; corrected pointer/wheel
  coordinates for independent CSS X/Y scaling; normalized initial focus and
  hidden-tab timing. Local Chromium runtime verification exercises rendering,
  input, resize, focus loss, and hidden-tab behavior.
- [Source-verified] Replaced Windows/macOS platform stubs with Win32 and
  AppKit/CAMetalLayer hosts, including portable input, resize/DPI, focus,
  close, cursor, and clipboard paths. Added X11's standard cursor roles while
  retaining an explicit error for its asynchronous clipboard and hidden-cursor
  boundary. Windows/macOS compile for their targets but have no
  runtime/presentation result.
- Removed the public renderer material no-op. Added physical common-key input,
  standard-profile controller snapshots, composition start/update/end events,
  and static input-capability reporting. Browser, XInput, evdev, and
  GameController adapters report unsupported optional facilities rather than
  rejecting host startup.
- Updated stale renderer, font, UI, error, performance, support, and public
  package documentation.

## Required work before a release declaration

1. Restore remote CI and obtain successful Linux, Windows, macOS, wasm, and
   browser jobs for the exact release commit. Compile-only results remain
   build evidence, not runtime support.
2. Runtime-test the implemented Windows and macOS hosts, or explicitly remove
   them from the advertised target set.
3. Run and record the manual GPU/device-loss/resize/hidden-window matrix in
   [SUPPORT.md](SUPPORT.md) and [PERFORMANCE.md](PERFORMANCE.md), including
   real hardware/browser versions and driver details.
4. Make the licensing decision and add a reviewed `LICENSE` plus third-party
   `NOTICE`; then produce reviewed artifacts and checksums through the release
   dry run.
5. Add physical-GPU image/readback and performance evidence. The deterministic
   software adapter guards translation correctness but cannot certify driver or
   presentation behavior.

## Important, non-blocking follow-up work

- Add optional GPU timestamps and a physical-GPU benchmark baseline before
  calling large sprite or tile scenes performance-ready.
- Runtime-test browser Gamepad/IME, Windows IMM/XInput, Linux evdev, and macOS
  GameController behavior. Implement macOS `NSTextInputClient` and Linux XIM
  before claiming composition support on those hosts.
- Before adding sprite sampling or blend choices, define typed engine semantics
  and backend conformance tests; arbitrary material parameters were removed as
  a misleading no-op.
- Keep editor tooling, 3D, networking, navigation, advanced animation, mobile,
  and consoles explicitly out of this milestone unless product scope changes.

## Verification record

This audit batch uses local `go test`, shuffled tests, race tests, `go vet`,
WebAssembly/native example builds, a deterministic software-WebGPU readback
test, `npm audit`, and `govulncheck`. The vulnerability scan initially found a
reachable malicious-font allocation issue in `golang.org/x/image`; the pinned
fixed version is now scanned clean. Remote GitHub Actions and runtime testing
on Windows/macOS remain unavailable.
