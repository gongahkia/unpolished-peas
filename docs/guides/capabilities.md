# v0.1 capability matrix

Generated from [`docs/capabilities/v0.1.json`](../capabilities/v0.1.json); do not edit manually.

Contract: `v0.1-draft`.

Browser baseline: current stable evergreen desktop releases of Chromium, Firefox, and Safari.

## Status

- `supported`: Part of the v0.1 release contract and exercised by the selected required CI lane.
- `preview`: Available for evaluation but excluded from the v0.1 release compatibility guarantee.
- `unsupported`: Not implemented or not offered by the v0.1 runtime contract.
- `removed`: Deliberately absent from the v0.1 runtime contract.

## Stable-core requirements

| Area | Requirement |
| --- | --- |
| Lifecycle | init once, fixed-step update, and one draw per presented frame |
| Drawing and text | Canvas primitives, sprites, and deterministic text |
| Keyboard and pointer | normalized keyboard and pointer state |
| Audio | bounded PCM playback and diagnostics |
| Assets | raw image, font, and audio asset loading |
| Fixed timestep | documented fixed-step timing and interpolation |
| Packaging | portable desktop package or static browser bundle |
| Deterministic hooks | headless commands, replay input, and local diagnostics |

## Target and renderer status

| Target | Renderer | Status | Required PR CI |
| --- | --- | --- | --- |
| macOS | SDL GPU | `supported` | `stable-core-capability` on `macos-15-intel` |
| macOS | OpenGL 3.3 | `preview` | — |
| Linux | SDL GPU | `supported` | `stable-core-capability` on `ubuntu-latest` |
| Linux | OpenGL 3.3 | `preview` | — |
| Windows | SDL GPU | `supported` | `stable-core-capability` on `windows-2022` |
| Windows | OpenGL 3.3 | `preview` | — |
| Chromium | WebGL 2 | `preview` | — |
| Chromium | WebGPU | `preview` | — |
| Firefox | WebGL 2 | `preview` | — |
| Firefox | WebGPU | `unsupported` | — |
| Safari | WebGL 2 | `preview` | — |
| Safari | WebGPU | `preview` | — |

WebGL 2 and WebGPU deliberately have the same stable-core requirement set. Their status differs only by implementation and release coverage.

## CI selection

`.github/workflows/toolchain.yml` obtains the required target matrix from this JSON through `script/capability_matrix.py`; it does not duplicate the selected targets.

| Matrix row | Runner | Core check |
| --- | --- | --- |
| `macos-sdl_gpu` | `macos-15-intel` | `bash script/test_stable_core_capability.sh macos-sdl_gpu` |
| `linux-sdl_gpu` | `ubuntu-latest` | `bash script/test_stable_core_capability.sh linux-sdl_gpu` |
| `windows-sdl_gpu` | `windows-2022` | `pwsh -File script/test_stable_core_capability.ps1 windows-sdl_gpu` |

## Nightly verification

Slow platform and browser coverage is selected here, separately from the required stable-core pull-request matrix.

| Matrix row | Runner | Check |
| --- | --- | --- |
| `macos-sdl_gpu` | `macos-15-intel` | `bash script/test_stable_core_capability.sh macos-sdl_gpu` |
| `linux-sdl_gpu` | `ubuntu-latest` | `bash script/test_stable_core_capability.sh linux-sdl_gpu` |
| `windows-sdl_gpu` | `windows-2022` | `pwsh -File script/test_stable_core_capability.ps1 windows-sdl_gpu` |
| `chromium-webgpu` | `macos-15-intel` | `zig build test-browser-chromium && zig build test-browser-renderer-parity && zig build benchmark-browser-workloads` |
| `firefox-webgl2` | `macos-15-intel` | `zig build test-browser-firefox` |
| `safari-webgl2` | `macos-26` | `safaridriver --enable && UP_SAFARI_RENDERERS=webgl2 zig build test-browser-safari` |
| `safari-webgpu` | `macos-26` | `safaridriver --enable && UP_SAFARI_RENDERERS=webgpu zig build test-browser-safari` |

## Release verification

Tag releases rerun every supported desktop capability before packaging.

| Matrix row | Runner | Check |
| --- | --- | --- |
| `macos-sdl_gpu` | `macos-15-intel` | `bash script/test_stable_core_capability.sh macos-sdl_gpu` |
| `linux-sdl_gpu` | `ubuntu-latest` | `bash script/test_stable_core_capability.sh linux-sdl_gpu` |
| `windows-sdl_gpu` | `windows-2022` | `pwsh -File script/test_stable_core_capability.ps1 windows-sdl_gpu` |
