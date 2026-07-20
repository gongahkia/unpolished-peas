# Input contract

v0.1 exposes normalized keyboard and pointer state through `up.input.Input`. The contract is identical for the native SDL host and browser hosts; renderer selection does not change input semantics.

## Keyboard and pointer

`Key` contains `up`, `down`, `left`, `right`, `action`, `cancel`, `start`, `select`, `debug`, and `screenshot`. Browser bindings normalize the documented DOM codes to those keys; native bindings normalize the corresponding SDL keys. `PointerButton` contains `left`, `middle`, `right`, `back`, and `forward`.

`isDown` and `pointerIsDown` remain true until the matching release. `wasPressed`, `wasReleased`, `pointerWasPressed`, and `pointerWasReleased` latch a transition once and clear at the next `beginFrame`/browser input read. Repeated down or up events do not create a second edge.

Pointer `window` coordinates are the host event coordinates. `framebuffer` coordinates are scaled to the physical drawing surface. `canvas` is the logical-canvas point after presentation mapping; it is null on native and non-finite in the browser ABI outside a letterboxed canvas destination. Pointer delta and wheel delta reset each frame.

## Focus and visibility

Native focus loss, browser window blur, browser canvas blur, and browser visibility loss release every held key and pointer button. The resulting release edges are visible for that frame, so focus changes cannot leave input stuck. Regaining focus does not synthesize presses.

`src/fixtures/input/keyboard-pointer-v1.json` is the shared keyboard/pointer fixture. Native input tests and browser-host tests consume it; forced WebGL 2 and WebGPU smoke tests additionally exercise focused keyboard, pointer, and focus-loss behavior on each renderer.
