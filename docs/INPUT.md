# portable input

Games receive `engine.Input` in `Application.Update` and `FixedApplication.FixedUpdate`.
They do not receive native window-system, browser, or adapter input values. A host
translates platform callbacks into `engine.Event` values and samples them through
`Runtime.SampleInput` on its event-loop goroutine before calling the runtime:

```go
events := runtime.Host().Events.PollEvents()
if err := runtime.Update(runtime.SampleInput(events)); err != nil {
    return err
}
```

`Input` retains action state (`Down`, `Pressed`, `Released`, and signed `Axis`),
and also exposes a pointer snapshot, committed UTF-8 text, IME composition, and
gamepad snapshots. Pointer positions, deltas, and scroll values are logical
engine pixels; hosts convert native device coordinates using their current DPI
scale before emitting `EventPointerMove` or `EventPointerWheel`.

## action maps and rebinding

Configure actions in `engine.Config`. A binding can combine keyboard keys,
gamepad buttons, and a signed axis. Axis keyboard bindings take priority over
the gamepad value when one direction is held. The action state remains down for
any configured source, and its `Value` is the active axis value.

```go
actions := engine.ActionMap{
    "jump": {Keys: []engine.Key{engine.KeySpace}},
    "move": {Axis: &engine.AxisBinding{
        Negative: []engine.Key{engine.KeyA},
        Positive: []engine.Key{engine.KeyD},
        GamepadAxis: 0,
        UseGamepad: true,
        Deadzone: .2,
    }},
}
```

`ActionMap.Clone` and `ActionMap.Rebind` make independent deep copies. To change
a running game's bindings, call `Runtime.SetActions` or `InputMapper.Rebind`.
Raw held controls are retained: the next sampled frame reports a release for an
old held binding, or a press for a newly bound control that is already held.
Invalid empty action names, empty keys, empty bindings, and axis deadzones
outside `[0, 1)` are rejected.

## text, pointer, gamepads, and focus

Keys identify physical locations, not characters from the active keyboard
layout. Hosts emit left/right modifier keys separately. `KeyShift` remains a
compatibility binding that matches either physical Shift key.

`EventText` carries committed text, not key strokes. `EventComposition` carries
`CompositionStart`, `CompositionUpdate`, and `CompositionEnd`; `Input.Composition`
returns those transitions and `Input.Preedit` exposes the active preedit value.
An end caused by focus loss is marked canceled. Applications own candidate UI,
selection, and text-editing policy outside this minimal preedit contract.

Pointer buttons are `PointerPrimary`, `PointerSecondary`, and `PointerMiddle`.
Use `Input.Pointer` for its position, per-update delta/scroll, and button edge
state. `Input.Pointer` returns a copy, so an application cannot modify an input
snapshot seen elsewhere in the frame.

The gamepad contract uses the [standard Gamepad mapping](https://www.w3.org/TR/gamepad/#remapping) semantics. `Input.Gamepads` returns DeviceID-ordered standard-profile snapshots: button values are `[0, 1]` and axes are `[-1, 1]`. Hosts report connection changes using `EventGamepadConnection`; games can read mapping/support metadata from `Input.GamepadConnections`. Unknown mappings deliberately do not produce a normalized snapshot. Values at or inside a configured axis deadzone are neutral. Non-finite position, scroll, or analog values and invalid UTF-8 text are ignored at the normalization boundary.

`runtime.Host().InputCapabilities()` returns the static host snapshot for
keyboard, composition, and standard gamepad support. `InputRestricted` means
the facility exists but the environment denied its use; `InputUnavailable`
means this host does not implement it. A capability does not imply a controller
is currently connected.

On `EventFocusChanged` with `Focused: false`, the mapper clears keyboard,
pointer-button, and gamepad held state. One release edge is emitted for any
previously held action or pointer button, so a game cannot remain stuck moving
after an alt-tab or browser focus loss. Pointer position is retained because it
is spatial state rather than a held control.

## host parity

Native and browser hosts must emit the event kinds and units described by
`engine.Event`; they must not pass platform key codes, layout-derived key names,
or raw physical pixels to games. `engine/input_test.go` feeds equivalent normalized event batches through
two independent mappers and requires equal snapshots. That contract test covers
the common mapping behavior; each concrete host also needs its own callback and
browser/window lifecycle tests.

The Linux X11 and browser hosts translate platform callbacks to `engine.Event`
batches before calling `Runtime.SampleInput`. The portable mapper, rather than
a host edge helper, derives press and release transitions. The Linux host has
local window-creation coverage; browser callback behavior requires runtime
browser verification. Browser keyboard, composition, and standard Gamepad API
support are exposed as available when the corresponding browser APIs exist.
