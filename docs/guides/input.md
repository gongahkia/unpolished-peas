# Input contract

v0.1 exposes normalized keyboard and pointer state through `up.input.Input`. The contract is identical for the native SDL host and browser hosts; renderer selection does not change input semantics.

## Keyboard and pointer

`Key` contains `up`, `down`, `left`, `right`, `action`, `cancel`, `start`, `select`, `debug`, and `screenshot`. Browser bindings normalize the documented DOM codes to those keys; native bindings normalize the corresponding SDL keys. `PointerButton` contains `left`, `middle`, `right`, `back`, and `forward`.

`isDown` and `pointerIsDown` remain true until the matching release. `wasPressed`, `wasReleased`, `pointerWasPressed`, and `pointerWasReleased` latch a transition once. Repeated down or up events do not create a second edge.

Hosts collect platform events during a presentation frame, then use an internal fixed-tick buffer to normalize them into one `up.input.Input.Snapshot` for each fixed simulation update. A snapshot describes the state observed during that update. If a presentation frame runs several updates, the first update receives the accumulated press/release edges, pointer delta, and wheel delta; later catch-up updates retain held state and absolute pointer position but receive no duplicate transient input. If a presentation frame runs zero updates, its input remains buffered until a later fixed update consumes it.

When several physical events occur before a fixed update, held state and absolute pointer position use the newest observation, keyboard/pointer/gamepad edges are accumulated, and pointer movement and wheel motion are summed. Gamepad axes use the newest value and retain the axis value from before the accumulated interval as `previousAxis`. This is intentionally a fixed-tick contract: game simulation should consume input in `update`, not infer event timing from `draw`.

Pointer `window` coordinates are the host event coordinates. `framebuffer` coordinates are scaled to the physical drawing surface. `canvas` is the logical-canvas point after presentation mapping; it is null on native and non-finite in the browser ABI outside a letterboxed canvas destination. Pointer delta and wheel delta are transient per simulation snapshot as described above.

Text input is not currently part of `Input`, so it is not represented in deterministic input snapshots or replays.

## Focus and visibility

Native focus loss releases every held key, pointer button, and gamepad button; native gamepad axes return to zero. Browser window blur, browser canvas blur, and browser visibility loss release every held key and pointer button. The resulting release edges are visible for that frame, so focus changes cannot leave input stuck. Regaining focus does not synthesize presses.

`src/fixtures/input/keyboard-pointer-v1.json` is the shared keyboard/pointer fixture. Native input tests and browser-host tests consume it; forced WebGL 2 and WebGPU smoke tests additionally exercise focused keyboard, pointer, and focus-loss behavior on each renderer.
