# Platform host contract

`engine.Host` separates the 72 runtime lifecycle from native windowing and
browser event-loop ownership. A host owns platform resources; the runtime owns
game lifecycle, ECS state, layers, and portable render commands. No public
engine API exposes an OS window, browser canvas, GPU device, or graphics
binding handle.

## Lifecycle and thread affinity

Use `engine.RunWithHost(config, app, host)` for an engine-owned platform host.
Before `Application.Initialize`, 72 reads `host.Context()` and installs its
`Window`, `Clock`, and `EventSource` on `Runtime.Host()`. This lets application
initialization configure portable title, cursor, or clipboard behavior without
depending on a host implementation.

The host calls `Host.Run` exactly once on its event-loop owner goroutine. It
must create and release platform resources, poll events, translate them to
`engine.Event`, invoke `Runtime.Update`, invoke `Runtime.FixedUpdate` if it
owns a fixed simulation clock, draw/present, and handle shutdown on that same
goroutine. Game code may use the installed `HostContext` only while `Run` is
active and must not retain native resources or call window/event methods from a
different goroutine.

The legacy `engine.Backend` interface remains for the Ebitengine compatibility
adapter. It supplies no `HostContext`; `Runtime.Host()` is its zero value there.
New native and browser integrations implement `engine.Host` instead.

## Window and timing

`Window.State` reports a host-owned snapshot:

- `LogicalSize` is the engine coordinate size.
- `DrawableSize` is the physical canvas or framebuffer size.
- `Scale` is physical pixels per logical pixel.
- `Focused`, `Visible`, and `CloseRequested` expose lifecycle state without
  selecting a platform close policy.

`SetTitle`, `SetCursor`, and clipboard calls return errors. If the operation is
not available on a platform, the host returns a contextual unsupported error;
it does not emulate a successful OS or browser operation in engine memory.

`Clock.Timing` returns a frame counter plus elapsed and delta durations. Hosts
own visibility/throttling behavior. The runtime does not infer fixed simulation
time from presentation delta; a host that needs fixed updates supplies its own
accumulator and calls `Runtime.FixedUpdate` with the appropriate normalized
input snapshot.

## Normalized events

`EventSource.PollEvents` returns and clears raw portable events accumulated
since the prior poll. Events cover keyboard, UTF-8 text, pointer motion/buttons
and wheel, gamepad connection/buttons/axes, focus changes, resize, and close
requests. Event fields are meaningful only for the event kind.

Hosts report `EventFocusChanged{Focused:false}` rather than inventing releases
for every held key or button. The input mapping layer consumes that event and
resets held actions; this makes focus-loss behavior explicit and testable. A
host must use only `engine.Key`, `GamepadButton`, `GamepadAxis`, `Vec2`, and
`WindowState` values in its event stream.

## Testing hosts

A fake host needs only the public interfaces. It supplies deterministic window
state, timing, and events, then calls runtime lifecycle methods from its own
`Run`. The runtime test suite includes such a fake and verifies that the
context is available during initialization without importing Ebitengine.
