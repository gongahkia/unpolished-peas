# Platform status

This is the canonical record of platform evidence. “Build/package” and
“runtime” are deliberately separate: a cross-build or CI package does not
prove an interactive runtime on that platform. Renderer/API contract status is
tracked separately in the [capability matrix](capabilities.md).

| Target | Build/package evidence | Runtime evidence | Notes |
| --- | --- | --- | --- |
| macOS x86_64 | Universal Seed Sprint package built, checksummed, and layout-checked | Validated on Intel macOS 15.7.7: Cocoa → SDL GPU → Metal, Retina 2× framebuffer, native audio device, and an embedded Neon Siege executable launched from `/tmp` | Tier 1 evidence on Intel macOS only |
| macOS arm64 | Universal arm64 slice cross-built on Intel macOS | Not run on Apple Silicon | Tier 1 target; cross-build is not arm64 runtime validation |
| Linux x86_64 under WSL2/WSLg | Local builds and package checks | Validated as **WSLg runtime only** with SDL GPU through the bridge | Useful development evidence, not bare-metal Linux proof |
| Native Linux x86_64 | CI/package coverage | No bare-metal interactive run recorded | Tier 1 target; Wayland/X11, GPU, audio, and controller behavior still need native-Linux evidence |
| Browser/Wasm | Automated Wasm, host, bundle, and external-project package tests | Chromium WebGL2/WebGPU pixel comparisons, material/post-pass captures, keyboard/recovery checks, and desktop/narrow-viewport visual inspection on Intel macOS (October 23, 2026) | Preview renderer targets; screen-reader, physical controller, and browser audio device behavior still need manual evidence |
| Windows x86_64 | CI package matrix | Not run locally | Secondary target |

## November 5 portable workflow evidence

On Intel macOS 15.7.7 with Zig 0.15.2, a downstream game fetched a real source
archive with its computed Zig package hash, built/tested/packaged, and launched
through Cocoa → SDL GPU/Metal with audio ready. Separate native processes
saved and restored progress in a fresh UUID namespace, then removed that test
store. Chromium WebGL 2 verified rendered assets, physical bindings and paused
taps, CDP Unicode composition, audio submissions, storage rejection/retry,
actual reload, and init/shutdown cleanup. Native and Wasm session replay agreed
on captured initial saves, progress bytes and pixels.

The [verification record](portable-conformance.md) gives exact commands and
artifact locations. These are automated local observations. Physical native
IME/controller/audio-quality/accessibility checks and new interactive Apple
Silicon, bare-metal Linux, Windows, Firefox and Safari evidence remain open.
Browser preview status is unchanged.

## WSLg runtime distinction

WSL2/WSLg is useful for normal development and catches SDL, browser-adjacent,
and packaging mistakes. Its graphics bridge, D3D12-backed Vulkan path,
PulseAudio bridge, and input routing are not equivalent to a native Linux
desktop. Do not use WSLg success as evidence for bare-metal Linux driver,
audio-stack, gamepad, Wayland, or X11 behavior.

## Common native startup checks

Peas leaves SDL video-driver selection alone. The native startup diagnostic
records the chosen video driver, requested and selected renderer, fallback
state, and failed backend attempts. For a one-off Linux diagnosis—not a
packaging policy—you may try an installed driver explicitly:

```sh
SDL_VIDEODRIVER=wayland zig build run
SDL_VIDEODRIVER=x11 zig build run
```

Do not bake either override into a game. A no-display environment should fail
quickly with a platform diagnostic; it is not evidence that the game renderer
is broken.
