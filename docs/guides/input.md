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

v1.0 exposes normalized keyboard and pointer state through `up.input.Input`. The contract is identical for the native SDL host and browser hosts; renderer selection does not change input semantics.

## Keyboard and pointer

`Key` contains `up`, `down`, `left`, `right`, `action`, `cancel`, `start`, `select`, `debug`, and `screenshot`. Browser bindings normalize the documented DOM codes to those keys; native bindings normalize the corresponding SDL keys. `PointerButton` contains `left`, `middle`, `right`, `back`, and `forward`.

`isDown` and `pointerIsDown` remain true until the matching release. `wasPressed`, `wasReleased`, `pointerWasPressed`, and `pointerWasReleased` latch a transition once. Repeated down or up events do not create a second edge.

Browser keyboard aliases remain held until every pressed physical alias is
released. Tab also reports `select`, but retains normal browser focus navigation
so keyboard users can leave the canvas. Shift is an alternative `select` binding.
On controllers with the browser's `standard` mapping, the two trigger axes use
the analog values of buttons 6 and 7; the four stick axes use axes 0 through 3.

Hosts collect platform events during a presentation frame, then use an internal fixed-tick buffer to normalize them into one `up.input.Input.Snapshot` for each fixed simulation update. A snapshot describes the state observed during that update. If a presentation frame runs several updates, the first update receives the accumulated press/release edges, pointer delta, and wheel delta; later catch-up updates retain held state and absolute pointer position but receive no duplicate transient input. If a presentation frame runs zero updates, its input remains buffered until a later fixed update consumes it.

When several physical events occur before a fixed update, held state and absolute pointer position use the newest observation, keyboard/pointer/gamepad edges are accumulated, and pointer movement and wheel motion are summed. Gamepad axes use the newest value and retain the axis value from before the accumulated interval as `previousAxis`. This is intentionally a fixed-tick contract: game simulation should consume input in `update`, not infer event timing from `draw`.

Buffered controller edges follow the controller ID when a browser snapshot
reorders its slots. Native and browser hosts share the same tick buffer;
paused and zero-update frames retain pending edges until an update consumes
them. Focus-loss releases therefore survive a pause without leaving keys held.

Pointer `window` coordinates are the host event coordinates. `framebuffer` coordinates are scaled to the physical drawing surface. `canvas` is the logical-canvas point after presentation mapping; it is null on native and non-finite in the browser ABI outside a letterboxed canvas destination. Pointer delta and wheel delta are transient per simulation snapshot as described above.

Physical keyboard and Unicode text/composition events are part of the extension described below. They are included in fixed-tick snapshots and UPR5 replay data; normalized-only recordings retain their previous formats.

## Focus and visibility

Native focus loss releases every held key, pointer button, and gamepad button; native gamepad axes return to zero. Browser window blur, browser canvas blur, and browser visibility loss release every held key and pointer button. The resulting release edges are visible for that frame, so focus changes cannot leave input stuck. Regaining focus does not synthesize presses.

`src/fixtures/input/keyboard-pointer-v1.json` is the shared keyboard/pointer fixture. Native input tests and browser-host tests consume it; forced WebGL 2 and WebGPU smoke tests additionally exercise focused keyboard, pointer, and focus-loss behavior on each renderer.


## Physical keys and rebinding

`up.input.Input.PhysicalKey` identifies keyboard positions using stable USB
keyboard-page values. It covers A–Z, `digit_0`–`digit_9`, punctuation, arrows,
editing/navigation keys, F1–F24, numpad keys, and left/right modifiers. These
identities are independent of the user's keyboard layout. Use text events to
obtain characters; converting physical keys to characters is not supported.
Unknown platform scancodes/codes are ignored.

```zig
const definitions = [_]up.input.Action{
    .{ .name = "interact", .binding = .{ .physical_key = .q } },
    .{ .name = "inventory", .binding = .{ .physical_key = .e } },
    .{ .name = "slot-one", .binding = .{ .physical_key = .digit_1 } },
    .{ .name = "slot-two", .binding = .{ .physical_key = .digit_2 } },
};
var actions = try up.input.ActionMap.init(allocator, &definitions);
defer actions.deinit();
try actions.rebind("game", "interact", .{ .physical_key = .r });
// During each update, after any rebind:
actions.update(ctx.input.*);
```

Owned action maps support `rebind`, `rebindBinding`, and `rebindAt`; immutable
borrowed definitions reject mutation with `ImmutableActionMap`. A rebind takes
effect in `value` immediately and in cached edges on the next `update`. The
ordinary action-edge rule applies when a held binding changes: old positive
value to zero releases, zero to positive presses. Native binding files retain
old entries and add a `physical` binding kind. In-memory rebinding is portable;
a freestanding host with an explicitly attached native app-data path returns
`ActionPersistenceUnavailable` and rolls the rebind back. Browser games can
store their own binding preferences through `SaveStore`.

Use `physicalIsDown`, `physicalWasPressed`, and `physicalWasReleased` for
physical state directly. `Input.extended.eventSlice()` adds arrival order and
keydown repeats. A key repeat has `event.repeat == true` and does not create
an additional pressed edge. Normalized controls, numeric key IDs, alias
behavior and the original keyboard/pointer fixture remain unchanged.

## Unicode text and composition

Normal desktop, browser and headless protocol hosts provide
`GameContext.text_input`. Request entry from `init` or `update`:

```zig
try ctx.setTextInput(true);
// Later, when the name/menu field closes:
try ctx.setTextInput(false);
```

This changes a host-owned request; the platform applies it at the next input
poll. `ctx.input.extended.active` reports actual activation. Text input starts
disabled. A bare context without this capability returns
`TextInputUnavailable`. Headless input builders use `setTextInputActive`,
`setPhysical`, `updateComposition`, and `commitText` to supply controlled host
observations; replay restores the recorded observations, not OS text services.

Read the extension events in fixed-step update:

```zig
for (ctx.input.extended.eventSlice()) |event| {
    switch (event.kind) {
        .text_commit => {
            const utf8 = ctx.input.extended.eventText(event);
            // Append these bytes to the game's bounded name buffer.
            _ = utf8;
        },
        .composition_update => {
            const preedit = ctx.input.extended.eventText(event);
            // Display separately; preedit is not committed game text.
            _ = preedit;
        },
        else => {},
    }
}
```

The event kinds are `key_down`, `key_up`, `text_commit`, `composition_start`,
`composition_update`, `composition_end`, `composition_cancel`, `text_started`
and `text_stopped`. Selection fields on composition updates count Unicode
code points; `-1/-1` means the platform did not provide a selection. Browser
composition events currently use that unknown selection value. Native SDL
preedit selection is preserved when valid. Physical events have a non-null
`key`; other kinds do not. Only keydown events can carry `repeat`.

Each extension owns 32 event records and 1024 UTF-8 payload bytes, with no
per-event Zig allocation. Text is copied into that storage. `eventSlice` and
`eventText` return borrowed views, valid until the input/snapshot is mutated;
copy anything retained by game state. Invalid UTF-8 is rejected as a whole,
and an event that exceeds remaining count/byte capacity is dropped as a whole.
`commitText`/`updateComposition` return an error to input builders; hosts drop
bad platform data. Overflow additionally latches `extended.overflow`, survives
zero-update frames, and clears after consumption. Held keys and final
active/composing state still update when an event is dropped. An editor should
stop entry and restart its session on overflow rather than use partial history.

Events from successive zero-update or paused frames append in arrival order.
Only the first catch-up update receives them; later updates retain held keys,
activation and composition state. A commit never comes from a keycode. Native
text events and the browser's actual textarea value/IME lifecycle supply it;
repeats therefore follow platform text editing without inventing characters.
Focus loss releases physical keys and cancels preedit. Deactivation cancels
preedit before `text_stopped`. Regaining focus reactivates a still-requested
session without synthesizing held keys. Native legacy Escape-to-quit remains
in effect outside text entry; during entry Escape cancels preedit instead.

The browser owns one visually hidden textarea positioned near the canvas for
IME/candidate placement. It receives normal Unicode input, paste, and real
composition events. Entry preserves Tab navigation, and explicit deactivation
returns focus to the canvas. Teardown removes the element and listeners. The
host consumes a committed textarea value once across browser differences in
whether final input arrives before or after compositionend.

Pointer and Tab transfers out of text entry cancel pending preedit before the
browser's default focus action can finalize it. A platform commit that has
already arrived before focus loss retains its place in the ordered stream.

## Portable input workbench

Read [game state](../../examples/input_workbench_game.zig) and the small
[native wrapper](../../examples/input_workbench.zig). Run:

```sh
zig build run-input-workbench
zig build test-input-workbench -Dwith_sdl=false
zig build web-input-workbench -Dwith_sdl=false
python3 -m http.server --directory zig-out/input-workbench 8000
```

Q/E move, 1/2 increment independent counters, F5 rebinds Q/R, and F4 toggles
name entry. Enter finishes a name; Escape cancels current preedit before
finishing. The example deletes code points rather than grapheme clusters and
keeps name/preedit text separate. Its bundled Source Sans 3 font covers the
authored Latin range; other entered Unicode remains intact in game state and
uses the font's missing-glyph fallback. Text shaping and a general text-editor
widget are outside this example.

See the [compatibility plan and wire layout](input-v2-compatibility.md) for
UPR5 and browser input ABI v2. Run `zig build test-browser-input` for host
normalization, `zig build test-browser-input-v2 -Dwith_sdl=false` for DOM-shaped
input through Wasm/game/replay, and `script/test_browser_input_workbench.sh`
for real Chromium textarea and IME protocol interaction.
