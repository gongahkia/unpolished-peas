package engine

import (
	"fmt"
	"time"
)

// WindowState is a host-owned snapshot of one application window or browser
// canvas. LogicalSize is measured in engine logical pixels; DrawableSize is the
// physical presentation size after DPI scaling.
type WindowState struct {
	Title          string
	LogicalSize    Size
	DrawableSize   Size
	Scale          float64
	Focused        bool
	Visible        bool
	CloseRequested bool
}

// Cursor selects a portable host cursor role.
type Cursor uint8

const (
	CursorDefault Cursor = iota
	CursorPointer
	CursorText
	CursorCrosshair
	CursorHidden
)

// PointerButton identifies a portable pointer button.
type PointerButton uint8

const (
	PointerPrimary PointerButton = iota
	PointerSecondary
	PointerMiddle
)

// Window exposes host-owned window state and presentation controls. A host may
// return a contextual unsupported-operation error for a platform capability it
// cannot provide; it must not silently emulate clipboard or cursor state.
type Window interface {
	State() WindowState
	SetTitle(string) error
	SetCursor(Cursor) error
	ReadClipboard() (string, error)
	WriteClipboard(string) error
}

// ClipboardOperation identifies an asynchronous clipboard operation.
type ClipboardOperation uint8

const (
	ClipboardRead ClipboardOperation = iota
	ClipboardWrite
)

// ClipboardRequestID identifies one accepted asynchronous clipboard request.
// IDs are unique only for the lifetime of the host that returned them.
type ClipboardRequestID uint64

// ClipboardRequest describes one asynchronous clipboard operation. Text is
// used only by ClipboardWrite.
type ClipboardRequest struct {
	Operation ClipboardOperation
	Text      string
}

// ClipboardCompletion is the terminal result of an asynchronous clipboard
// request. Text is populated only for a successful ClipboardRead.
type ClipboardCompletion struct {
	ID        ClipboardRequestID
	Operation ClipboardOperation
	Text      string
	Err       error
}

// AsyncClipboard is an optional, owner-goroutine clipboard interface for
// hosts whose clipboard API is asynchronous. RequestClipboard returns after a
// request has been accepted; PollClipboard returns terminal completions in
// settlement order and clears them from the host.
type AsyncClipboard interface {
	RequestClipboard(ClipboardRequest) (ClipboardRequestID, error)
	PollClipboard() []ClipboardCompletion
}

// FrameTiming is a host-generated frame snapshot. Delta is the elapsed wall
// time since the prior presentation frame; fixed simulation cadence remains an
// application or runtime policy rather than a host assumption.
type FrameTiming struct {
	Frame   uint64
	Elapsed time.Duration
	Delta   time.Duration
}

// Clock supplies host-owned timing snapshots. A host owns all monotonic-time
// sampling so browser visibility and native event-loop policy stay outside the
// game API.
type Clock interface {
	Now() time.Time
	Timing() FrameTiming
}

// EventKind identifies a normalized host event.
type EventKind uint8

const (
	EventKey EventKind = iota
	EventText
	EventPointerMove
	EventPointerButton
	EventPointerWheel
	EventGamepadConnection
	EventGamepadButton
	EventGamepadAxis
	EventFocusChanged
	EventWindowResized
	EventCloseRequested
	EventComposition
)

// Event is a normalized input or lifecycle event. Only fields relevant to Kind
// are populated. Action maps deliberately remain separate: hosts report raw
// portable controls, while the runtime/application owns action binding.
type Event struct {
	Kind                EventKind
	Key                 Key
	Button              GamepadButton
	PointerButton       PointerButton
	Axis                GamepadAxis
	DeviceID            uint32
	Position            Vec2
	Scroll              Vec2
	Text                string
	Value               float64
	Pressed             bool
	Connected           bool
	GamepadMapping      GamepadMapping
	GamepadUnsupported  bool
	Composition         CompositionPhase
	CompositionCanceled bool
	Focused             bool
	Window              WindowState
}

// EventSource returns events accumulated since its prior call. PollEvents must
// be called only by the host's event-loop owner goroutine.
type EventSource interface {
	PollEvents() []Event
}

// InputCapability reports whether one normalized input family is usable for a
// host context. Restricted means the API exists but the current environment
// denied its use; unavailable means the host does not implement it.
type InputCapability uint8

const (
	InputUnavailable InputCapability = iota
	InputAvailable
	InputRestricted
)

// InputCapabilities is the host snapshot captured when Context is requested.
// It does not imply a device is connected; Gamepad describes whether standard
// controller observation is supported at all.
type InputCapabilities struct {
	Keyboard    InputCapability
	Composition InputCapability
	Gamepad     InputCapability
}

// InputCapabilitySource is optionally implemented by a host Window. Hosts
// that do not implement it expose InputUnavailable for every capability.
type InputCapabilitySource interface {
	InputCapabilities() InputCapabilities
}

// HostContext is the application-visible, host-owned platform boundary. Its
// interfaces remain valid only while Host.Run is active on the owner goroutine.
type HostContext struct {
	Window Window
	Clock  Clock
	Events EventSource
}

// InputCapabilities returns this host's static normalized-input capabilities.
// The result deliberately remains available without a backend-specific type.
func (c HostContext) InputCapabilities() InputCapabilities {
	if source, ok := c.Window.(InputCapabilitySource); ok {
		return source.InputCapabilities()
	}
	return InputCapabilities{}
}

// AsyncClipboard returns the host's optional asynchronous clipboard facility.
// It is absent when the host has only the synchronous Window clipboard
// contract or cannot provide clipboard access.
func (c HostContext) AsyncClipboard() (AsyncClipboard, bool) {
	clipboard, ok := c.Window.(AsyncClipboard)
	return clipboard, ok
}

func (c HostContext) validate() error {
	if c.Window == nil {
		return fmt.Errorf("host window must not be nil")
	}
	if c.Clock == nil {
		return fmt.Errorf("host clock must not be nil")
	}
	if c.Events == nil {
		return fmt.Errorf("host event source must not be nil")
	}
	return nil
}

// Host owns a native or browser event loop and presents runtime frames. Run is
// called exactly once on the host owner goroutine. Hosts must invoke Runtime
// update/draw methods only from that same goroutine, poll Events there, and
// stop before releasing Window, Clock, or presentation resources.
//
// Host implementations own platform callbacks, window/canvas creation,
// clipboard/cursor calls, DPI changes, visibility, and close policy. Runtime
// code owns game lifecycle and must not retain native handles or call a Host
// from another goroutine.
type Host interface {
	Backend
	Context() HostContext
}
