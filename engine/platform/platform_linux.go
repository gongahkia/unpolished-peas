//go:build linux

// Package platform owns 72's native and browser host implementations.
package platform

import (
	"fmt"
	"runtime"
	"time"
	"unsafe"

	"github.com/go-webgpu/goffi/ffi"
	"github.com/go-webgpu/goffi/types"
	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render/webgpu"
	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
)

const (
	xButtonPrimary    = 1
	xButtonMiddle     = 2
	xButtonSecondary  = 3
	xButtonScrollUp   = 4
	xButtonScrollDown = 5

	xCursorCrosshair = 34
	xCursorHand      = 58
	xCursorDefault   = 68
	xCursorText      = 152
)

// Run starts the Linux X11 host. It owns the X11 event loop and uses the
// private WebGPU renderer; no framework window or renderer participates.
func Run(config engine.Config, app engine.Application) error {
	host, err := newX11Host(config)
	if err != nil {
		return err
	}
	defer host.close()
	return engine.RunWithHost(config, app, host)
}

type x11Host struct {
	config     engine.Config
	xlib       *xlib
	conn       *xgb.Conn
	windowID   xproto.Window
	wmDelete   xproto.Atom
	keysyms    map[xproto.Keycode][]xproto.Keysym
	renderer   *webgpu.Renderer
	cursor     xproto.Cursor
	cursorFont xproto.Font

	state  engine.WindowState
	events []engine.Event
	frame  uint64
	last   time.Time
	timing engine.FrameTiming
}

func newX11Host(config engine.Config) (*x11Host, error) {
	if config.Viewport.W <= 0 || config.Viewport.H <= 0 || config.WindowScale <= 0 {
		return nil, fmt.Errorf("create X11 host: configuration has an invalid viewport or window scale")
	}
	logicalWidth, logicalHeight := int(config.Viewport.W), int(config.Viewport.H)
	if float64(logicalWidth) != config.Viewport.W || float64(logicalHeight) != config.Viewport.H {
		return nil, fmt.Errorf("create X11 host: viewport dimensions must be integral pixels")
	}
	physicalWidth, physicalHeight := logicalWidth*config.WindowScale, logicalHeight*config.WindowScale
	if physicalWidth <= 0 || physicalHeight <= 0 || physicalWidth > 65535 || physicalHeight > 65535 {
		return nil, fmt.Errorf("create X11 host: presentation size is outside X11's supported range")
	}

	conn, err := xgb.NewConn()
	if err != nil {
		return nil, fmt.Errorf("open X11 connection: %w", err)
	}
	cleanupConnection := true
	defer func() {
		if cleanupConnection {
			conn.Close()
		}
	}()

	screen := xproto.Setup(conn).DefaultScreen(conn)
	window, err := xproto.NewWindowId(conn)
	if err != nil {
		return nil, fmt.Errorf("allocate X11 window: %w", err)
	}
	eventMask := uint32(xproto.EventMaskKeyPress |
		xproto.EventMaskKeyRelease |
		xproto.EventMaskButtonPress |
		xproto.EventMaskButtonRelease |
		xproto.EventMaskPointerMotion |
		xproto.EventMaskStructureNotify |
		xproto.EventMaskFocusChange)
	if err := xproto.CreateWindowChecked(conn, screen.RootDepth, window, screen.Root,
		0, 0, uint16(physicalWidth), uint16(physicalHeight), 0,
		xproto.WindowClassInputOutput, screen.RootVisual,
		xproto.CwBackPixel|xproto.CwEventMask,
		[]uint32{screen.BlackPixel, eventMask},
	).Check(); err != nil {
		return nil, fmt.Errorf("create X11 window: %w", err)
	}

	wmProtocols, err := internAtom(conn, "WM_PROTOCOLS")
	if err != nil {
		return nil, err
	}
	wmDelete, err := internAtom(conn, "WM_DELETE_WINDOW")
	if err != nil {
		return nil, err
	}
	if err := setWindowProtocols(conn, window, wmProtocols, wmDelete); err != nil {
		return nil, err
	}
	if err := setWindowTitle(conn, window, config.Title); err != nil {
		return nil, err
	}
	keysyms, err := loadKeysyms(conn)
	if err != nil {
		return nil, err
	}

	xlib, err := openXlib()
	if err != nil {
		return nil, err
	}
	renderer, err := webgpu.NewXlib(xlib.display, uintptr(window), physicalWidth, physicalHeight)
	if err != nil {
		xlib.close()
		return nil, err
	}
	if err := renderer.SetLogicalSize(logicalWidth, logicalHeight); err != nil {
		renderer.Close()
		xlib.close()
		return nil, err
	}

	now := time.Now()
	host := &x11Host{
		config: config, xlib: xlib, conn: conn, windowID: window, wmDelete: wmDelete,
		keysyms: keysyms, renderer: renderer, last: now,
		state: engine.WindowState{
			Title: config.Title, LogicalSize: engine.Size{W: config.Viewport.W, H: config.Viewport.H},
			DrawableSize: engine.Size{W: float64(physicalWidth), H: float64(physicalHeight)},
			Scale:        float64(config.WindowScale), Focused: true, Visible: true,
		},
	}
	if err := xproto.MapWindowChecked(conn, window).Check(); err != nil {
		host.close()
		return nil, fmt.Errorf("map X11 window: %w", err)
	}
	cleanupConnection = false
	return host, nil
}

func internAtom(conn *xgb.Conn, name string) (xproto.Atom, error) {
	reply, err := xproto.InternAtom(conn, false, uint16(len(name)), name).Reply()
	if err != nil {
		return 0, fmt.Errorf("intern X11 atom %q: %w", name, err)
	}
	return reply.Atom, nil
}

func setWindowProtocols(conn *xgb.Conn, window xproto.Window, wmProtocols, wmDelete xproto.Atom) error {
	data := make([]byte, 4)
	xgb.Put32(data, uint32(wmDelete))
	if err := xproto.ChangePropertyChecked(conn, xproto.PropModeReplace, window, wmProtocols, xproto.AtomAtom, 32, 1, data).Check(); err != nil {
		return fmt.Errorf("set X11 window protocols: %w", err)
	}
	return nil
}

func setWindowTitle(conn *xgb.Conn, window xproto.Window, title string) error {
	if err := xproto.ChangePropertyChecked(conn, xproto.PropModeReplace, window, xproto.AtomWmName, xproto.AtomString, 8, uint32(len(title)), []byte(title)).Check(); err != nil {
		return fmt.Errorf("set X11 window title: %w", err)
	}
	return nil
}

func loadKeysyms(conn *xgb.Conn) (map[xproto.Keycode][]xproto.Keysym, error) {
	setup := xproto.Setup(conn)
	count := int(setup.MaxKeycode) - int(setup.MinKeycode) + 1
	if count <= 0 || count > 255 {
		return nil, fmt.Errorf("load X11 keyboard mapping: invalid keycode range %d..%d", setup.MinKeycode, setup.MaxKeycode)
	}
	reply, err := xproto.GetKeyboardMapping(conn, setup.MinKeycode, byte(count)).Reply()
	if err != nil {
		return nil, fmt.Errorf("load X11 keyboard mapping: %w", err)
	}
	if reply.KeysymsPerKeycode == 0 {
		return nil, fmt.Errorf("load X11 keyboard mapping: server returned no keysyms")
	}
	keysyms := make(map[xproto.Keycode][]xproto.Keysym, count)
	perKeycode := int(reply.KeysymsPerKeycode)
	for offset := 0; offset < count; offset++ {
		start := offset * perKeycode
		keysyms[xproto.Keycode(int(setup.MinKeycode)+offset)] = reply.Keysyms[start : start+perKeycode]
	}
	return keysyms, nil
}

func (h *x11Host) Context() engine.HostContext {
	return engine.HostContext{Window: h, Clock: h, Events: h}
}

func (h *x11Host) Run(appRuntime *engine.Runtime) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	next := time.Now()
	for !h.state.CloseRequested {
		if err := h.pollNative(); err != nil {
			return fmt.Errorf("poll X11 events: %w", err)
		}
		if h.state.CloseRequested {
			break
		}
		now := time.Now()
		h.frame++
		h.timing = engine.FrameTiming{Frame: h.frame, Elapsed: now.Sub(h.last), Delta: now.Sub(h.last)}
		h.last = now
		if err := appRuntime.Update(appRuntime.SampleInput(h.PollEvents())); err != nil {
			return err
		}
		if err := appRuntime.Draw(h.renderer); err != nil {
			return err
		}
		next = next.Add(time.Second / 60)
		if delay := time.Until(next); delay > 0 {
			time.Sleep(delay)
		} else {
			next = time.Now()
		}
	}
	return nil
}

func (h *x11Host) State() engine.WindowState { return h.state }

func (h *x11Host) SetTitle(value string) error {
	if err := setWindowTitle(h.conn, h.windowID, value); err != nil {
		return err
	}
	h.state.Title = value
	return nil
}

func (h *x11Host) SetCursor(cursor engine.Cursor) error {
	glyph, ok := xCursorGlyph(cursor)
	if !ok {
		return fmt.Errorf("set X11 cursor %d: hidden cursors are not implemented", cursor)
	}
	if h.cursorFont == 0 {
		font, err := xproto.NewFontId(h.conn)
		if err != nil {
			return fmt.Errorf("allocate X11 cursor font: %w", err)
		}
		if err := xproto.OpenFontChecked(h.conn, font, uint16(len("cursor")), "cursor").Check(); err != nil {
			return fmt.Errorf("open X11 cursor font: %w", err)
		}
		h.cursorFont = font
	}
	value, err := xproto.NewCursorId(h.conn)
	if err != nil {
		return fmt.Errorf("allocate X11 cursor: %w", err)
	}
	if err := xproto.CreateGlyphCursorChecked(h.conn, value, h.cursorFont, h.cursorFont, glyph, glyph+1, 0, 0, 0, 0xffff, 0xffff, 0xffff).Check(); err != nil {
		return fmt.Errorf("create X11 cursor: %w", err)
	}
	if err := xproto.ChangeWindowAttributesChecked(h.conn, h.windowID, xproto.CwCursor, []uint32{uint32(value)}).Check(); err != nil {
		_ = xproto.FreeCursorChecked(h.conn, value).Check()
		return fmt.Errorf("apply X11 cursor: %w", err)
	}
	previous := h.cursor
	h.cursor = value
	if previous != 0 {
		if err := xproto.FreeCursorChecked(h.conn, previous).Check(); err != nil {
			return fmt.Errorf("release previous X11 cursor: %w", err)
		}
	}
	return nil
}

func (*x11Host) ReadClipboard() (string, error) {
	return "", fmt.Errorf("read X11 clipboard: selection ownership is not implemented")
}

func (*x11Host) WriteClipboard(string) error {
	return fmt.Errorf("write X11 clipboard: selection ownership is not implemented")
}

func (h *x11Host) Now() time.Time             { return time.Now() }
func (h *x11Host) Timing() engine.FrameTiming { return h.timing }

func (h *x11Host) PollEvents() []engine.Event {
	events := append([]engine.Event(nil), h.events...)
	h.events = h.events[:0]
	return events
}

func (h *x11Host) pollNative() error {
	for {
		event, xerr := h.conn.PollForEvent()
		if xerr != nil {
			return fmt.Errorf("X11 server error: %s", xerr.Error())
		}
		if event == nil {
			return nil
		}
		switch event := event.(type) {
		case xproto.KeyPressEvent:
			h.appendKey(event.Detail, event.State, true)
		case xproto.KeyReleaseEvent:
			key := xproto.KeyPressEvent(event)
			h.appendKey(key.Detail, key.State, false)
		case xproto.ButtonPressEvent:
			h.appendButton(uint32(event.Detail), event.EventX, event.EventY, true)
		case xproto.ButtonReleaseEvent:
			button := xproto.ButtonPressEvent(event)
			h.appendButton(uint32(button.Detail), button.EventX, button.EventY, false)
		case xproto.MotionNotifyEvent:
			h.events = append(h.events, engine.Event{Kind: engine.EventPointerMove, Position: xPoint(event.EventX, event.EventY)})
		case xproto.FocusInEvent:
			h.state.Focused = true
			h.events = append(h.events, engine.Event{Kind: engine.EventFocusChanged, Focused: true})
		case xproto.FocusOutEvent:
			h.state.Focused = false
			h.events = append(h.events, engine.Event{Kind: engine.EventFocusChanged, Focused: false})
		case xproto.ConfigureNotifyEvent:
			if err := h.resize(int(event.Width), int(event.Height)); err != nil {
				return err
			}
		case xproto.ClientMessageEvent:
			if event.Type == h.wmDelete || (len(event.Data.Data32) > 0 && xproto.Atom(event.Data.Data32[0]) == h.wmDelete) {
				h.state.CloseRequested = true
				h.events = append(h.events, engine.Event{Kind: engine.EventCloseRequested, Window: h.state})
			}
		}
	}
}

func (h *x11Host) appendKey(keycode xproto.Keycode, state uint16, pressed bool) {
	keysym := h.keysym(keycode, state)
	if key, ok := xKey(uint64(keysym)); ok {
		h.events = append(h.events, engine.Event{Kind: engine.EventKey, Key: key, Pressed: pressed})
	}
	if pressed {
		if text := xText(uint64(keysym)); text != "" {
			h.events = append(h.events, engine.Event{Kind: engine.EventText, Text: text})
		}
	}
}

func (h *x11Host) keysym(keycode xproto.Keycode, state uint16) xproto.Keysym {
	values := h.keysyms[keycode]
	if len(values) == 0 {
		return 0
	}
	index := 0
	if state&xproto.ModMaskShift != 0 && len(values) > 1 && values[1] != 0 {
		index = 1
	}
	return values[index]
}

func (h *x11Host) appendButton(button uint32, x, y int16, pressed bool) {
	if button == xButtonScrollUp || button == xButtonScrollDown {
		if pressed {
			delta := 1.0
			if button == xButtonScrollDown {
				delta = -1
			}
			h.events = append(h.events, engine.Event{Kind: engine.EventPointerWheel, Scroll: engine.Vec2{Y: delta}})
		}
		return
	}
	if portable, ok := pointerButton(button); ok {
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: portable, Pressed: pressed, Position: xPoint(x, y)})
	}
}

func (h *x11Host) resize(width, height int) error {
	if width <= 0 || height <= 0 || (width == int(h.state.DrawableSize.W) && height == int(h.state.DrawableSize.H)) {
		return nil
	}
	if err := h.renderer.Resize(width, height); err != nil {
		return err
	}
	h.state.DrawableSize = engine.Size{W: float64(width), H: float64(height)}
	h.state.Scale = float64(width) / h.config.Viewport.W
	h.events = append(h.events, engine.Event{Kind: engine.EventWindowResized, Window: h.state})
	return nil
}

func (h *x11Host) close() {
	if h == nil {
		return
	}
	if h.renderer != nil {
		h.renderer.Close()
		h.renderer = nil
	}
	if h.conn != nil {
		if h.cursor != 0 {
			_ = xproto.FreeCursorChecked(h.conn, h.cursor).Check()
			h.cursor = 0
		}
		if h.cursorFont != 0 {
			_ = xproto.CloseFontChecked(h.conn, h.cursorFont).Check()
			h.cursorFont = 0
		}
		if h.windowID != 0 {
			_ = xproto.DestroyWindowChecked(h.conn, h.windowID).Check()
			h.windowID = 0
		}
		h.conn.Close()
		h.conn = nil
	}
	if h.xlib != nil {
		h.xlib.close()
		h.xlib = nil
	}
}

func pointerButton(button uint32) (engine.PointerButton, bool) {
	switch button {
	case xButtonPrimary:
		return engine.PointerPrimary, true
	case xButtonSecondary:
		return engine.PointerSecondary, true
	case xButtonMiddle:
		return engine.PointerMiddle, true
	default:
		return 0, false
	}
}

func xCursorGlyph(cursor engine.Cursor) (uint16, bool) {
	switch cursor {
	case engine.CursorDefault:
		return xCursorDefault, true
	case engine.CursorPointer:
		return xCursorHand, true
	case engine.CursorText:
		return xCursorText, true
	case engine.CursorCrosshair:
		return xCursorCrosshair, true
	default:
		return 0, false
	}
}

func xPoint(x, y int16) engine.Vec2 {
	return engine.Vec2{X: float64(x), Y: float64(y)}
}

func xText(keysym uint64) string {
	if keysym >= 0x20 && keysym <= 0x7e {
		return string(rune(keysym))
	}
	return ""
}

func xKey(keysym uint64) (engine.Key, bool) {
	switch keysym {
	case 'a', 'A':
		return engine.KeyA, true
	case 'd', 'D':
		return engine.KeyD, true
	case 'e', 'E':
		return engine.KeyE, true
	case 'j', 'J':
		return engine.KeyJ, true
	case 'p', 'P':
		return engine.KeyP, true
	case 's', 'S':
		return engine.KeyS, true
	case 'w', 'W':
		return engine.KeyW, true
	case 0x20:
		return engine.KeySpace, true
	case 0xffe1, 0xffe2:
		return engine.KeyShift, true
	case 0xff0d:
		return engine.KeyEnter, true
	case '.':
		return engine.KeyPeriod, true
	case 0xff09:
		return engine.KeyTab, true
	case 0xff54:
		return engine.KeyArrowDown, true
	case 0xff51:
		return engine.KeyArrowLeft, true
	case 0xff53:
		return engine.KeyArrowRight, true
	case 0xff52:
		return engine.KeyArrowUp, true
	case 0xffbe:
		return engine.KeyF1, true
	case 0xffbf:
		return engine.KeyF2, true
	case 0xffc3:
		return engine.KeyF6, true
	default:
		return "", false
	}
}

type xlib struct {
	library unsafe.Pointer
	display uintptr
	calls   map[string]xcall
}

type xcall struct {
	symbol unsafe.Pointer
	cif    types.CallInterface
}

func openXlib() (*xlib, error) {
	library, err := ffi.LoadLibrary("libX11.so.6")
	if err != nil {
		return nil, fmt.Errorf("load libX11.so.6: %w", err)
	}
	x := &xlib{library: library, calls: make(map[string]xcall)}
	for _, definition := range []struct {
		name   string
		result *types.TypeDescriptor
		args   []*types.TypeDescriptor
	}{
		{"XOpenDisplay", types.PointerTypeDescriptor, []*types.TypeDescriptor{types.PointerTypeDescriptor}},
		{"XCloseDisplay", types.SInt32TypeDescriptor, []*types.TypeDescriptor{types.PointerTypeDescriptor}},
	} {
		if err := x.prepare(definition.name, definition.result, definition.args); err != nil {
			x.close()
			return nil, err
		}
	}
	var name uintptr
	var display uintptr
	if _, err := x.call("XOpenDisplay", unsafe.Pointer(&display), []unsafe.Pointer{unsafe.Pointer(&name)}); err != nil || display == 0 {
		x.close()
		if err != nil {
			return nil, fmt.Errorf("open X display: %w", err)
		}
		return nil, fmt.Errorf("open X display: XOpenDisplay returned null")
	}
	x.display = display
	return x, nil
}

func (x *xlib) prepare(name string, result *types.TypeDescriptor, args []*types.TypeDescriptor) error {
	symbol, err := ffi.GetSymbol(x.library, name)
	if err != nil {
		return fmt.Errorf("resolve %s: %w", name, err)
	}
	var cif types.CallInterface
	if err := ffi.PrepareCallInterface(&cif, types.DefaultCall, result, args); err != nil {
		return fmt.Errorf("prepare %s: %w", name, err)
	}
	x.calls[name] = xcall{symbol: symbol, cif: cif}
	return nil
}

func (x *xlib) call(name string, result unsafe.Pointer, args []unsafe.Pointer) (int, error) {
	call, ok := x.calls[name]
	if !ok {
		return 0, fmt.Errorf("Xlib call %s is unavailable", name)
	}
	_, err := ffi.CallFunction(&call.cif, call.symbol, result, args)
	return 0, err
}

func (x *xlib) close() {
	if x == nil {
		return
	}
	if x.display != 0 {
		var status int32
		_, _ = x.call("XCloseDisplay", unsafe.Pointer(&status), []unsafe.Pointer{unsafe.Pointer(&x.display)})
		x.display = 0
	}
	if x.library != nil {
		_ = ffi.FreeLibrary(x.library)
		x.library = nil
	}
}
