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
and also exposes a pointer snapshot, committed UTF-8 text, and gamepad connection
changes. Pointer positions, deltas, and scroll values are logical engine pixels;
hosts convert native device coordinates using their current DPI scale before
emitting `EventPointerMove` or `EventPointerWheel`.

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

`EventText` carries committed text, not key strokes or IME composition updates.
`Input.Text` returns only the valid UTF-8 strings committed in that update. A
text widget owns composition UI and policy outside this minimal runtime input
contract.

Pointer buttons are `PointerPrimary`, `PointerSecondary`, and `PointerMiddle`.
Use `Input.Pointer` for its position, per-update delta/scroll, and button edge
state. `Input.Pointer` returns a copy, so an application cannot modify an input
snapshot seen elsewhere in the frame.

Hosts report connection changes using `EventGamepadConnection`; games can read
them from `Input.GamepadConnections`. Button and axis events identify the same
`DeviceID`. Axis values are clamped to `[-1, 1]`; values at or inside the
configured deadzone are neutral. Non-finite position, scroll, or axis values
and invalid UTF-8 text are ignored at the normalization boundary.

On `EventFocusChanged` with `Focused: false`, the mapper clears keyboard,
pointer-button, and gamepad held state. One release edge is emitted for any
previously held action or pointer button, so a game cannot remain stuck moving
after an alt-tab or browser focus loss. Pointer position is retained because it
is spatial state rather than a held control.

## host parity

Native and browser hosts must emit the event kinds and units described by
`engine.Event`; they must not pass platform key codes or raw physical pixels to
games. `engine/input_test.go` feeds equivalent normalized event batches through
two independent mappers and requires equal snapshots. That contract test covers
the common mapping behavior; each concrete host also needs its own callback and
browser/window lifecycle tests.

The temporary `engine/ebiten` adapter predates the host contract and currently
provides action sampling only. It is not evidence of native/browser pointer,
text, or gamepad parity; those host implementations are tracked separately.
