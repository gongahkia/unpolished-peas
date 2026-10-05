# Input and actions

Start with named game actions rather than scattering physical keyboard or
controller checks through gameplay. An `ActionMap` lets one action have both a
keyboard and gamepad binding; the game asks for `"left"` or `"dash"`, not a
backend event.

The compiled Seed Sprint source declares these keyboard and gamepad bindings:

<!-- BEGIN seed-sprint-actions -->
```zig
const actions = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "left", .binding = .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1 } } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "right", .binding = .{ .gamepad_axis = .{ .axis = .left_x } } },
    .{ .name = "up", .binding = .{ .key = .up } },
    .{ .name = "up", .binding = .{ .gamepad_axis = .{ .axis = .left_y, .sign = -1 } } },
    .{ .name = "down", .binding = .{ .key = .down } },
    .{ .name = "down", .binding = .{ .gamepad_axis = .{ .axis = .left_y } } },
    .{ .name = "dash", .binding = .{ .key = .action } },
    .{ .name = "dash", .binding = .{ .gamepad_button = .south } },
};
```
<!-- END seed-sprint-actions -->

Inside fixed-step `update`, it reads those named actions instead of physical
events:

<!-- BEGIN seed-sprint-action-update -->
```zig
        const bindings = up.input.ActionMap{ .actions = &actions };
        const input = ctx.input.*;
        const dash_multiplier: f32 = if (bindings.value(input, "game", "dash") > 0) 1.8 else 1.0;
        const speed = movement_speed * dash_multiplier;
        const dx = bindings.value(input, "game", "right") - bindings.value(input, "game", "left");
        const dy = bindings.value(input, "game", "down") - bindings.value(input, "game", "up");
```
<!-- END seed-sprint-action-update -->

This is an excerpt from
[`templates/starter/src/game.zig`](../../templates/starter/src/game.zig), which
is compiled by the starter tests. Bindings are game-owned: Peas does not
reserve ordinary gameplay keys for developer tools.

Use `isDown`/`ActionMap.value` for held movement and `wasPressed` or
`wasReleased` for one-time actions such as restart, menus, or a dash trigger.
Read input in fixed-step `update`, not `draw`.

## Normalized input contract

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
