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

The legacy `engine.Backend` interface remains for custom event-loop adapters.
It supplies no `HostContext`; `Runtime.Host()` is its zero value there. Native
and browser integrations implement `engine.Host` instead.

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
since the prior poll. Events cover keyboard, UTF-8 text, IME composition,
pointer motion/buttons and wheel, gamepad connection/buttons/axes, focus
changes, resize, and close requests. Event fields are meaningful only for the
event kind. Hosts should also implement `InputCapabilitySource` through their
Window value so games can distinguish unavailable or restricted composition and
gamepad facilities without probing platform APIs.

Hosts report `EventFocusChanged{Focused:false}` rather than inventing releases
for every held key or button. The input mapping layer consumes that event and
resets held actions; this makes focus-loss behavior explicit and testable. A
host must use only `engine.Key`, `GamepadButton`, `GamepadAxis`, `Vec2`, and
`WindowState` values in its event stream.

## Browser lifecycle behavior

The wasm host owns its canvas, schedules frames through
`requestAnimationFrame`, and does not attempt a WebGL or Canvas fallback when
WebGPU cannot initialize. Window `focus`/`blur` becomes
`EventFocusChanged`; pointer down focuses its private text input. A `visibilitychange` to
hidden marks the window invisible, emits a focus-loss event when needed, and
skips update/draw callbacks. On return to visible it resets the frame-time
baseline before the next update, so hidden-tab time is not delivered as one
large simulation delta. Resize reads the canvas CSS rectangle and maps each
axis independently to logical coordinates before reconfiguring the renderer.

This is [Source-verified] behavior compiled for wasm. A local Chromium smoke
exercises rendering, input, resize, focus loss, and hidden-tab transitions.
Browser-device loss and all behavior on other browser/driver combinations still
need runtime evidence before becoming support claims.

## Native desktop lifecycle behavior

The Windows host owns a Win32 `HWND`, pumps messages on its owner thread, and
creates a private WebGPU surface from that window. It normalizes key, UTF-16
text, pointer, wheel, focus, resize, minimize, close, and cursor operations
before passing only portable values to `engine`. Its Unicode clipboard methods
transfer ownership through the native clipboard APIs. Zero-sized client areas
suspend the renderer until a subsequent resize, and the host resets its frame
delta baseline while presentation is suspended.

The macOS host owns an AppKit `NSWindow`, its `NSView`, and a `CAMetalLayer`.
It pumps `NSEvent` records on the locked main thread, maps backing scale to the
physical drawable, converts AppKit pointer coordinates to engine coordinates,
and handles the same portable lifecycle and clipboard/cursor boundaries. It
uses the renderer's existing FFI foundation for Objective-C calls, so the host
does not introduce a second native runtime into the process. `platform.Run`
returns an error unless it is entered on the process main thread; AppKit UI
work cannot be safely migrated to an arbitrary goroutine. A minimized or
invisible window suspends the surface and resets the next frame's delta
baseline.

Both paths are [Source-verified] through target compilation and portable event
mapping tests. They have no Windows or macOS runtime/presentation evidence yet;
they remain build-only targets in [SUPPORT.md](SUPPORT.md).

The Linux X11 host supports the standard default, pointer, text, and crosshair
cursor roles through the X cursor font. It returns an explicit unsupported
error for a hidden cursor and for clipboard transfer: X selection ownership is
asynchronous and cannot honestly satisfy the synchronous `Window` contract.

## Testing hosts

A fake host needs only the public interfaces. It supplies deterministic window
state, timing, and events, then calls runtime lifecycle methods from its own
`Run`. The runtime test suite includes such a fake and verifies that the
context is available during initialization without importing a platform binding.
