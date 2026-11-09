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
| Browser/Wasm | Automated Wasm, host, bundle, and external-project package tests | Chromium WebGL2/WebGPU pixel comparisons and earlier visual inspection; November 6 WebGL 2 authoring workflows passed in Chromium, Firefox and real Safari on Intel macOS, as detailed below | Preview renderer targets; screen-reader, physical controller, physical IME and speaker-quality behavior still need manual evidence |
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
Silicon, bare-metal Linux and Windows evidence remain open. Newer automated
Firefox/Safari workflow evidence is recorded below.
Browser preview status is unchanged.

## November 10 local diagnostics evidence

On the same Intel macOS 15.7.7 host, Zig 0.15.2 and Node 24.19.0, the opt-in
logging authoring matrix passed all nine WebGL 2 cases in Chromium
157.0.8103.38, Firefox 158.0 and real Safari 18.6. Each case retained parseable
session-correlated records, reported zero console-sink errors and passed a real
JSON/non-interactive support export. The consumer's repeated compiled failures
retained the latest four distinct incidents with visible drop counters and no
resource/callback leaks. Existing font pixels, audio activation, saves/reload,
input, renderer readback and independent PNG checks remained required.

Nine compiled native cases verified init/update/draw/cleanup failures, repeat
launches, filters, blocked output, explicit disable and early video failure
through Cocoa → SDL GPU/Metal (dummy audio). Original errors/operations and
applicable PNG/context artifacts survived support export. The
[dated record](../reviews/2026-11-10-local-diagnostics.md) gives commands, limits
and artifact locations. This is local automated evidence; browser preview and
the outstanding physical/hardware checks above are unchanged.

## November 6 browser authoring evidence

On Intel macOS 15.7.7, Zig 0.15.2 and Node 24.19.0, the external archive
consumer plus compiled font-layout and audio-lifetime examples passed the
same WebGL 2 assertions in Google Chrome 157.0.8103.38, Playwright Firefox
158.0 and real macOS Safari 18.6 through Safari WebDriver. This is nine
workflow/browser combinations; Safari is not represented by Playwright WebKit.

Checks include trusted physical-key automation and releases, rebinding,
injected DOM composition, trusted Unicode input, actual save/reload, rejected
save recovery, authored image/font/atlas pixels, partial-init cleanup/retry and
shutdown. Font frames match native CPU references within one RGBA channel
value, including centered labels and wrapped dialogue. Audio checks cover
gesture activation, finite nonzero accepted PCM, twelve scene transitions,
paused-source release and bounded resource-slot counts.

Safari required enabling Allow remote automation. Each browser independently
passed the blank-page WebGL/PNG probe and Peas renderer readback. The shared
checks use no CDP. Composition events are explicitly injected; this does not
establish physical OS IME behavior, controller/accessibility coverage, speaker
quality or other hardware results. All browser renderer statuses remain preview.
See [browser authoring verification](browser-authoring.md) for commands,
artifacts, automation fixes and unverified-prerequisite behavior.

## November 8 surface-composition evidence

The opt-in [surface compositor](gpu-surface-composition.md) passed actual
SDL GPU/Metal readbacks on the same Intel Mac: 24 small fixtures across two
logical sizes, plus all four compiled mixed-workload configurations. Opaque
nearest and CPU fallback fixtures were exact. Observed maximum RGBA channel
deltas were 3 for alpha/linear fixtures and 3 for the mixed workload against
the original CPU rendering. Existing exact CPU goldens were retained.

Real Chrome 157.0.8103.38, Firefox 158.0 and Safari 18.6 passed the same twelve
WebGL 2 surface cases, each with observed maximum delta 3. All three also
passed resource-creation rollback/retry, repeated release/generation churn,
direct source mutation, actual WebGL context loss/restoration, backing resize
and shutdown with zero live game resources/scheduled frames. Independent
WebGL readback and PNG probes remain required, including Safari's existing
capture rules. Renderer/version metadata and captures are retained under
`zig-out/diagnostics/surface-gpu/`.

These are local Intel macOS observations. Apple Silicon, Vulkan/D3D native
hardware, other operating systems and other GPUs remain unverified for this
new path. OpenGL/WebGPU explicitly reject it. Preview status is unchanged.

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
