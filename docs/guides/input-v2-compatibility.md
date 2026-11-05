# Physical keyboard and text input compatibility plan

This plan precedes implementation of the portable-input extension. Existing
normalized `Key` identities, their numeric values, and their snapshot masks
remain unchanged. Physical keys are a separate `Input.PhysicalKey` enum using
USB keyboard-page identities (also used by SDL scancodes). `ActionBinding`
gains an additive `physical_key` case; existing rebind and persistence APIs
continue to work.

## Game and fixed-step contract

`GameContext` gains an optional host-owned text-input control and a portable
`setTextInput(bool)` request. Normal native, browser, and headless hosts supply
it. No SDL or DOM types enter game code. Text entry is opt-in. Physical held
state and edges are separate from an ordered stream containing key transitions
and repeats, text commits, composition start/update/end/cancel, and text
activation changes. Composition text is preedit, never a committed name.

Input owns fixed arrays: 32 events and 1024 UTF-8 payload bytes per accumulated
tick. Payloads are copied; views borrow the snapshot until its next mutation.
Invalid UTF-8 and overlong events are rejected atomically; overflow drops the
newest event and latches an observable overflow flag. Physical held state and
activation state remain current even when events overflow. Games can stop name
entry and request a fresh session on overflow.

Presentation frames append events in arrival order. Zero-update/paused frames
retain them; the first fixed update consumes them; catch-up updates see held
state without repeated events. Repeat keydowns are events, not extra pressed
edges. Committed text comes only from platform text events, not keycode-to-text
conversion. Focus loss releases physical keys and cancels preedit. Text-input
deactivation cancels composition. Selection offsets count Unicode code points;
`-1` means unavailable. Native legacy Escape-to-quit is retained outside an
enabled text-entry session.

## Wire and replay compatibility

- UPR1–UPR4 parsing retains existing behavior and initializes extension fields
  to empty. Recordings with no extension data keep their existing byte format,
  hashes, seed/environment encoding, and goldens.
- UPR5 carries optional seed/environment metadata plus each legacy frame and a
  length-delimited extension. The extension uses explicit little-endian fields,
  physical bitsets, event records, and UTF-8 bytes; no struct-memory encoding.
  New recordings validate bounds, key IDs, booleans, selection ranges, UTF-8,
  and trailing bytes before playback.
- Browser input ABI v1 stays 376 bytes with the same offsets and import names.
  ABI v2 keeps that prefix and adds the bounded extension. Hosts choose v2 only
  with an explicit request marker and sufficient capacity; otherwise they retain
  v1 even for a larger legacy buffer. A v2 reader writes a marker and text-enabled
  flag before `input_read`; a v1 host simply overwrites the legacy prefix.
  The new runtime accepts either response. No new mandatory Wasm import is
  introduced, and the enclosing browser host ABI remains unchanged.
- The browser host uses a focused, visually hidden textarea near the canvas
  for real input/IME events,
  preserving Tab navigation and returning focus to the canvas on deactivation.
  It records composition separately and consumes committed DOM value once
  across final-input/compositionend ordering differences.

## Validation required

Retain all existing replay/Canvas goldens and API checks. Add physical binding
and persistence tests; ordered buffering/repeat/focus/overflow/Unicode tests;
UPR5 round trips and malformed-data tests; browser v1/v2 negotiation and real
textarea event checks; native event mapping/lifecycle tests; and one portable
example that demonstrates Q/E/1/2, rebinding, and Unicode name/preedit display.
Record available platform and browser validation separately from physical IME
hardware checks. README files are outside this implementation's scope.

Platform references: [SDL scancodes](https://wiki.libsdl.org/SDL3/SDL_Scancode),
[SDL text activation](https://wiki.libsdl.org/SDL3/SDL_StartTextInput),
[SDL preedit offsets](https://wiki.libsdl.org/SDL3/SDL_TextEditingEvent), and
[UI composition events](https://w3c.github.io/uievents/#events-compositionevents).


## Implemented layouts

The enclosing browser host ABI stays at version 6. Input v2 is 1890 bytes:
legacy offsets 0–375 (version word now 2), `u16` extension length at 376,
extension bytes at 378, and zero padding. A capacity of 376–1889 always requests v1; a larger buffer without the
request marker also receives v1.
A v2 reader places request marker `0x32515055` at offset 0 and the desired
text-enabled bit at offset 4 before reading. A v1 host overwrites that request
with its original response. The new runtime accepts either returned length.

The shared extension has 32-byte held/pressed/released bitsets at 0/32/64;
active, composing, overflow and event-count bytes at 96/97/98/99; a `u16` UTF-8
byte count at 100; and zero reserved bytes at 102/103. Each following 12-byte
event contains kind, physical key (0 for none), repeat, zero reserved byte,
`u16` text offset/length, and `i16` selection start/length. The final contiguous
UTF-8 pool follows the used records. Payload ranges must be consecutive; unused
record/buffer storage is never serialized. Maximum extension size is 1512.

UPR5 has a 32-byte header: magic; `u32` fixed Hz, flags and RNG ID; `u64`
seed; `u32` frame count and environment-byte count. Flag 1 indicates a seed;
flag 2 indicates the existing UPR4 environment encoding and requires flag 1.
Absent seed/RNG/environment fields must be zero. Optional environment bytes
precede frames. Each frame is the unchanged legacy 290 bytes plus a `u16`
extension length and its exact bytes. All integers are little-endian.

Adding `physical_key` requires applications with exhaustive `ActionBinding`
switches to handle that case. This source-level addition is explicit; no old
union tag or normalized key is repurposed. Core namespace snapshots and all
existing wire-format/pixel goldens remain checks on the old contract.

## Verification record — November 5, 2026

Verified locally with Zig 0.15.2 on Intel macOS. The combined portable suite
passed 85/85 build steps and 380/380 tests, including the unchanged legacy
replay goldens, fixed-step input buffering, binding persistence, malformed
UPR5 data, and the actual browser-input-to-Wasm-to-game replay path:

```sh
zig build test test-core-api test-support test-replays test-scenes \
  test-starter test-dogfood test-lantern-leap test-docs docs \
  test-frame-timing test-browser-runtime test-browser-input \
  test-browser-input-v2 test-browser-protocol-host test-browser-wasm-host \
  test-browser-replay test-browser-host test-browser-webgpu \
  -Dwith_sdl=false --summary all
```

Additional successful commands:

```sh
zig build test-sdl --summary all
zig build check-examples --summary all
zig build test-browser-input-v2 web-input-workbench -Dwith_sdl=false --summary all
zig build test-web-package --summary all
zig build run-input-workbench -- --frames 2
node script/test_browser_input.mjs
script/test_browser_input_workbench.sh
script/test_browser_shell.sh
zig fmt --check build.zig src examples templates
git diff --check
actionlint .github/workflows/toolchain.yml
bash -n script/test_browser_input_workbench.sh
```

The SDL suite passed 63/63 tests, including real window text-input
activation/deactivation and composition cancellation on focus loss. All 39
example build steps passed. The native example launched through Cocoa and
SDL GPU/Metal with audio ready. The real Chromium check exercised the portable
game's text-entry request, Unicode commits, CDP IME preedit/commit/cancel,
repeated identical commits, external focus transfer, held-key release, and
textarea cleanup. The existing Chromium shell and material checks also passed.

This record does not claim physical IME interaction on every native OS,
hardware keyboard/layout coverage, or a new Firefox/Safari interactive run.
The example retains Unicode input but its bundled font renders unsupported
glyphs as fallback; it is a code-point editor without shaping or grapheme
navigation. Browser composition selection offsets remain unavailable (`-1`).
Audio output, font coverage, and a full text editor are separate from the
deterministic input/replay contract. README files were left unchanged.
