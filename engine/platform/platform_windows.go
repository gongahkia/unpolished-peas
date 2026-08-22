//go:build windows

package platform

import (
	"fmt"
	"math"
	"runtime"
	"sync"
	"time"
	"unicode/utf16"
	"unsafe"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render/webgpu"
	"golang.org/x/sys/windows"
)

const (
	win32ClassName = "72EngineWindow"

	win32CSOwnDC            = 0x0020
	win32WSOverlappedWindow = 0x00cf0000
	win32CWUseDefault       = ^uintptr(0x7fffffff)
	win32SWShow             = 5

	win32PMRemove = 0x0001

	win32WMSize                = 0x0005
	win32WMSetFocus            = 0x0007
	win32WMKillFocus           = 0x0008
	win32WMSetCursor           = 0x0020
	win32WMChar                = 0x0102
	win32WMIMEStartComposition = 0x010d
	win32WMIMEEndComposition   = 0x010e
	win32WMIMEComposition      = 0x010f
	win32WMSysKeyDown          = 0x0104
	win32WMSysKeyUp            = 0x0105
	win32WMKeyDown             = 0x0100
	win32WMKeyUp               = 0x0101
	win32WMMouseMove           = 0x0200
	win32WMLButtonDown         = 0x0201
	win32WMLButtonUp           = 0x0202
	win32WMRButtonDown         = 0x0204
	win32WMRButtonUp           = 0x0205
	win32WMMButtonDown         = 0x0207
	win32WMMButtonUp           = 0x0208
	win32WMMouseWheel          = 0x020a
	win32WMClose               = 0x0010
	win32WMDestroy             = 0x0002
	win32WMShowWindow          = 0x0018
	win32WMDPIChanged          = 0x02e0
	win32WMQuit                = 0x0012

	win32SizeMinimized = 1

	win32HTClient = 1

	win32SWPNoMove     = 0x0002
	win32SWPNoZOrder   = 0x0004
	win32SWPNoActivate = 0x0010

	win32IDCArrow = 32512
	win32IDCText  = 32513
	win32IDCCross = 32515
	win32IDCHand  = 32649

	win32WheelDelta = 120

	win32CFUnicodeText = 13
	win32GMEMMoveable  = 0x0002

	// Leave ample signed-32-bit headroom for the non-client frame added by
	// AdjustWindowRectEx before CreateWindowEx receives the outer size.
	win32MaxClientDimension = 1 << 30
	win32GCSCompStr         = 0x0008
)

var (
	win32Kernel32 = windows.NewLazySystemDLL("kernel32.dll")
	win32User32   = windows.NewLazySystemDLL("user32.dll")
	win32XInput   = windows.NewLazySystemDLL("xinput1_4.dll")
	win32Imm32    = windows.NewLazySystemDLL("imm32.dll")

	win32GetModuleHandleW         = win32Kernel32.NewProc("GetModuleHandleW")
	win32GlobalAlloc              = win32Kernel32.NewProc("GlobalAlloc")
	win32GlobalFree               = win32Kernel32.NewProc("GlobalFree")
	win32GlobalLock               = win32Kernel32.NewProc("GlobalLock")
	win32GlobalUnlock             = win32Kernel32.NewProc("GlobalUnlock")
	win32GlobalSize               = win32Kernel32.NewProc("GlobalSize")
	win32RtlMoveMemory            = win32Kernel32.NewProc("RtlMoveMemory")
	win32RegisterClassExW         = win32User32.NewProc("RegisterClassExW")
	win32CreateWindowExW          = win32User32.NewProc("CreateWindowExW")
	win32DestroyWindow            = win32User32.NewProc("DestroyWindow")
	win32DefWindowProcW           = win32User32.NewProc("DefWindowProcW")
	win32PeekMessageW             = win32User32.NewProc("PeekMessageW")
	win32TranslateMessage         = win32User32.NewProc("TranslateMessage")
	win32DispatchMessageW         = win32User32.NewProc("DispatchMessageW")
	win32ShowWindow               = win32User32.NewProc("ShowWindow")
	win32UpdateWindow             = win32User32.NewProc("UpdateWindow")
	win32GetClientRect            = win32User32.NewProc("GetClientRect")
	win32AdjustWindowRectEx       = win32User32.NewProc("AdjustWindowRectEx")
	win32SetWindowTextW           = win32User32.NewProc("SetWindowTextW")
	win32SetWindowPos             = win32User32.NewProc("SetWindowPos")
	win32LoadCursorW              = win32User32.NewProc("LoadCursorW")
	win32SetCursor                = win32User32.NewProc("SetCursor")
	win32ShowCursor               = win32User32.NewProc("ShowCursor")
	win32OpenClipboard            = win32User32.NewProc("OpenClipboard")
	win32CloseClipboard           = win32User32.NewProc("CloseClipboard")
	win32GetClipboardData         = win32User32.NewProc("GetClipboardData")
	win32EmptyClipboard           = win32User32.NewProc("EmptyClipboard")
	win32SetClipboardData         = win32User32.NewProc("SetClipboardData")
	win32XInputGetState           = win32XInput.NewProc("XInputGetState")
	win32ImmGetContext            = win32Imm32.NewProc("ImmGetContext")
	win32ImmReleaseContext        = win32Imm32.NewProc("ImmReleaseContext")
	win32ImmGetCompositionStringW = win32Imm32.NewProc("ImmGetCompositionStringW")

	win32ClassOnce sync.Once
	win32ClassErr  error
	win32HostsMu   sync.RWMutex
	win32Hosts     = make(map[uintptr]*win32Host)
)

// Run starts the Win32 host. It creates and uses native resources from one OS
// thread; the private WebGPU renderer remains hidden behind the host contract.
func Run(config engine.Config, app engine.Application) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	host, err := newWin32Host(config)
	if err != nil {
		return err
	}
	defer host.close()
	return engine.RunWithHost(config, app, host)
}

type win32Host struct {
	config   engine.Config
	window   uintptr
	renderer *webgpu.Renderer

	state  engine.WindowState
	events []engine.Event
	frame  uint64
	timing engine.FrameTiming
	start  time.Time
	last   time.Time

	cursor            uintptr
	cursorHidden      bool
	pendingHigh       uint16
	preedit           string
	inputCapabilities engine.InputCapabilities
	gamepads          map[uint32]win32Gamepad
}

type win32Gamepad struct {
	buttons [17]float64
	axes    [4]float64
}

type win32XInputState struct {
	PacketNumber uint32
	Gamepad      win32XInputGamepad
}

type win32XInputGamepad struct {
	Buttons      uint16
	LeftTrigger  uint8
	RightTrigger uint8
	ThumbLX      int16
	ThumbLY      int16
	ThumbRX      int16
	ThumbRY      int16
}

type win32WNDCLASSEX struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSm     uintptr
}

type win32Point struct{ X, Y int32 }

type win32Message struct {
	Window  uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Point   win32Point
}

type win32Rect struct{ Left, Top, Right, Bottom int32 }

func newWin32Host(config engine.Config) (*win32Host, error) {
	if math.IsNaN(config.Viewport.W) || math.IsInf(config.Viewport.W, 0) || math.IsNaN(config.Viewport.H) || math.IsInf(config.Viewport.H, 0) || config.Viewport.W <= 0 || config.Viewport.H <= 0 || config.WindowScale <= 0 {
		return nil, fmt.Errorf("create Win32 host: configuration has an invalid viewport or window scale")
	}
	if err := config.Actions.Validate(); err != nil {
		return nil, fmt.Errorf("create Win32 host: %w", err)
	}
	logicalWidth, logicalHeight := int(config.Viewport.W), int(config.Viewport.H)
	if float64(logicalWidth) != config.Viewport.W || float64(logicalHeight) != config.Viewport.H {
		return nil, fmt.Errorf("create Win32 host: viewport dimensions must be integral pixels")
	}
	if logicalWidth > win32MaxClientDimension/config.WindowScale || logicalHeight > win32MaxClientDimension/config.WindowScale {
		return nil, fmt.Errorf("create Win32 host: presentation size is outside the supported range")
	}
	if err := registerWin32Class(); err != nil {
		return nil, err
	}
	instance, _, err := win32GetModuleHandleW.Call(0)
	if instance == 0 {
		return nil, win32Error("get Win32 module handle", err)
	}
	className, err := windows.UTF16PtrFromString(win32ClassName)
	if err != nil {
		return nil, fmt.Errorf("encode Win32 class name: %w", err)
	}
	title, err := windows.UTF16PtrFromString(config.Title)
	if err != nil {
		return nil, fmt.Errorf("encode Win32 title: %w", err)
	}
	clientWidth, clientHeight := logicalWidth*config.WindowScale, logicalHeight*config.WindowScale
	windowRect := win32Rect{Right: int32(clientWidth), Bottom: int32(clientHeight)}
	if result, _, callErr := win32AdjustWindowRectEx.Call(uintptr(unsafe.Pointer(&windowRect)), win32WSOverlappedWindow, 0, 0); result == 0 {
		return nil, win32Error("adjust Win32 window rectangle", callErr)
	}
	window, _, callErr := win32CreateWindowExW.Call(
		0, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(title)), win32WSOverlappedWindow,
		win32CWUseDefault, win32CWUseDefault, uintptr(windowRect.Right-windowRect.Left), uintptr(windowRect.Bottom-windowRect.Top),
		0, 0, instance, 0,
	)
	if window == 0 {
		return nil, win32Error("create Win32 window", callErr)
	}
	now := time.Now()
	host := &win32Host{
		config: config, window: window,
		state: engine.WindowState{Title: config.Title, LogicalSize: config.Viewport, Focused: true, Visible: true},
		start: now, last: now, inputCapabilities: engine.InputCapabilities{Keyboard: engine.InputAvailable}, gamepads: make(map[uint32]win32Gamepad),
	}
	if win32XInput.Load() == nil {
		host.inputCapabilities.Gamepad = engine.InputAvailable
	}
	if win32Imm32.Load() == nil {
		host.inputCapabilities.Composition = engine.InputAvailable
	}
	arrow, _, arrowErr := win32LoadCursorW.Call(0, win32IDCArrow)
	if arrow == 0 {
		host.close()
		return nil, win32Error("load Win32 arrow cursor", arrowErr)
	}
	host.cursor = arrow
	registerWin32Host(host)

	if _, _, callErr = win32ShowWindow.Call(window, win32SWShow); callErr != nil && callErr != windows.ERROR_SUCCESS {
		host.close()
		return nil, win32Error("show Win32 window", callErr)
	}
	if result, _, callErr := win32UpdateWindow.Call(window); result == 0 {
		host.close()
		return nil, win32Error("update Win32 window", callErr)
	}
	if err := host.refreshDrawable(); err != nil {
		host.close()
		return nil, err
	}
	host.events = nil
	renderer, err := webgpu.NewWin32(window, int(host.state.DrawableSize.W), int(host.state.DrawableSize.H))
	if err != nil {
		host.close()
		return nil, fmt.Errorf("create Win32 WebGPU renderer: %w", err)
	}
	host.renderer = renderer
	if err := renderer.SetLogicalSize(logicalWidth, logicalHeight); err != nil {
		host.close()
		return nil, err
	}
	return host, nil
}

func registerWin32Class() error {
	win32ClassOnce.Do(func() {
		instance, _, err := win32GetModuleHandleW.Call(0)
		if instance == 0 {
			win32ClassErr = win32Error("get Win32 module handle", err)
			return
		}
		className, err := windows.UTF16PtrFromString(win32ClassName)
		if err != nil {
			win32ClassErr = fmt.Errorf("encode Win32 class name: %w", err)
			return
		}
		cursor, _, cursorErr := win32LoadCursorW.Call(0, win32IDCArrow)
		if cursor == 0 {
			win32ClassErr = win32Error("load Win32 arrow cursor", cursorErr)
			return
		}
		class := win32WNDCLASSEX{
			Size: uint32(unsafe.Sizeof(win32WNDCLASSEX{})), Style: win32CSOwnDC,
			WndProc: windows.NewCallback(win32WindowProc), Instance: instance, Cursor: cursor, ClassName: className,
		}
		atom, _, registerErr := win32RegisterClassExW.Call(uintptr(unsafe.Pointer(&class)))
		if atom == 0 && registerErr != windows.ERROR_CLASS_ALREADY_EXISTS {
			win32ClassErr = win32Error("register Win32 window class", registerErr)
		}
	})
	return win32ClassErr
}

func (h *win32Host) Context() engine.HostContext {
	return engine.HostContext{Window: h, Clock: h, Events: h}
}

func (h *win32Host) InputCapabilities() engine.InputCapabilities { return h.inputCapabilities }

func (h *win32Host) Run(appRuntime *engine.Runtime) error {
	if appRuntime == nil {
		return fmt.Errorf("run Win32 host: runtime must not be nil")
	}
	next := time.Now()
	for !h.state.CloseRequested {
		if err := h.pollNative(); err != nil {
			return err
		}
		if h.state.CloseRequested {
			break
		}
		if err := h.refreshDrawable(); err != nil {
			return err
		}
		if !h.state.Visible {
			now := time.Now()
			h.last, next = now, now
			time.Sleep(time.Second / 60)
			continue
		}
		now := h.Now()
		h.frame++
		h.timing = engine.FrameTiming{Frame: h.frame, Elapsed: now.Sub(h.start), Delta: now.Sub(h.last)}
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

func (h *win32Host) State() engine.WindowState { return h.state }

func (h *win32Host) SetTitle(value string) error {
	title, err := windows.UTF16PtrFromString(value)
	if err != nil {
		return fmt.Errorf("set Win32 title: %w", err)
	}
	if result, _, callErr := win32SetWindowTextW.Call(h.window, uintptr(unsafe.Pointer(title))); result == 0 {
		return win32Error("set Win32 window title", callErr)
	}
	h.state.Title = value
	return nil
}

func (h *win32Host) SetCursor(cursor engine.Cursor) error {
	if cursor == engine.CursorHidden {
		if !h.cursorHidden {
			win32ShowCursor.Call(0)
			h.cursorHidden = true
		}
		return nil
	}
	if h.cursorHidden {
		win32ShowCursor.Call(1)
		h.cursorHidden = false
	}
	identifier, ok := win32CursorID(cursor)
	if !ok {
		return fmt.Errorf("set Win32 cursor: unsupported cursor %d", cursor)
	}
	value, _, callErr := win32LoadCursorW.Call(0, identifier)
	if value == 0 {
		return win32Error("load Win32 cursor", callErr)
	}
	h.cursor = value
	win32SetCursor.Call(value)
	return nil
}

func (h *win32Host) ReadClipboard() (string, error) {
	if result, _, callErr := win32OpenClipboard.Call(h.window); result == 0 {
		return "", win32Error("open Win32 clipboard", callErr)
	}
	defer win32CloseClipboard.Call()
	handle, _, callErr := win32GetClipboardData.Call(win32CFUnicodeText)
	if handle == 0 {
		if callErr != nil && callErr != windows.ERROR_SUCCESS {
			return "", win32Error("read Win32 clipboard", callErr)
		}
		return "", fmt.Errorf("read Win32 clipboard: Unicode text is unavailable")
	}
	size, _, callErr := win32GlobalSize.Call(handle)
	if size == 0 {
		return "", win32Error("measure Win32 clipboard text", callErr)
	}
	if size%2 != 0 || size/2 > uintptr(maxInt()) {
		return "", fmt.Errorf("read Win32 clipboard: Unicode text has an invalid size")
	}
	memory, _, callErr := win32GlobalLock.Call(handle)
	if memory == 0 {
		return "", win32Error("lock Win32 clipboard text", callErr)
	}
	defer win32GlobalUnlock.Call(handle)
	units := make([]uint16, int(size/2))
	win32RtlMoveMemory.Call(uintptr(unsafe.Pointer(&units[0])), memory, size)
	runtime.KeepAlive(units)
	return windows.UTF16ToString(units), nil
}

func (h *win32Host) WriteClipboard(value string) error {
	units, err := windows.UTF16FromString(value)
	if err != nil {
		return fmt.Errorf("encode Win32 clipboard text: %w", err)
	}
	if len(units) == 0 || len(units) > maxInt()/2 {
		return fmt.Errorf("write Win32 clipboard: Unicode text is too large")
	}
	size := uintptr(len(units) * 2)
	handle, _, callErr := win32GlobalAlloc.Call(win32GMEMMoveable, size)
	if handle == 0 {
		return win32Error("allocate Win32 clipboard text", callErr)
	}
	ownedByClipboard := false
	defer func() {
		if !ownedByClipboard {
			win32GlobalFree.Call(handle)
		}
	}()
	memory, _, callErr := win32GlobalLock.Call(handle)
	if memory == 0 {
		return win32Error("lock Win32 clipboard text", callErr)
	}
	win32RtlMoveMemory.Call(memory, uintptr(unsafe.Pointer(&units[0])), size)
	runtime.KeepAlive(units)
	win32GlobalUnlock.Call(handle)
	if result, _, callErr := win32OpenClipboard.Call(h.window); result == 0 {
		return win32Error("open Win32 clipboard", callErr)
	}
	defer win32CloseClipboard.Call()
	if result, _, callErr := win32EmptyClipboard.Call(); result == 0 {
		return win32Error("clear Win32 clipboard", callErr)
	}
	if result, _, callErr := win32SetClipboardData.Call(win32CFUnicodeText, handle); result == 0 {
		return win32Error("write Win32 clipboard", callErr)
	}
	ownedByClipboard = true
	return nil
}

func (h *win32Host) Now() time.Time             { return time.Now() }
func (h *win32Host) Timing() engine.FrameTiming { return h.timing }

func (h *win32Host) PollEvents() []engine.Event {
	events := append([]engine.Event(nil), h.events...)
	h.events = h.events[:0]
	return events
}

func (h *win32Host) pollNative() error {
	for {
		var message win32Message
		result, _, callErr := win32PeekMessageW.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0, win32PMRemove)
		if result == 0 {
			if callErr != nil && callErr != windows.ERROR_SUCCESS {
				return win32Error("poll Win32 events", callErr)
			}
			h.pollGamepads()
			return nil
		}
		if message.Message == win32WMQuit {
			h.requestClose()
			return nil
		}
		win32TranslateMessage.Call(uintptr(unsafe.Pointer(&message)))
		win32DispatchMessageW.Call(uintptr(unsafe.Pointer(&message)))
	}
}

func (h *win32Host) refreshDrawable() error {
	if h.window == 0 {
		return fmt.Errorf("refresh Win32 drawable: window is closed")
	}
	var client win32Rect
	if result, _, callErr := win32GetClientRect.Call(h.window, uintptr(unsafe.Pointer(&client))); result == 0 {
		return win32Error("read Win32 client rectangle", callErr)
	}
	width, height := int(client.Right-client.Left), int(client.Bottom-client.Top)
	if width <= 0 || height <= 0 {
		h.state.Visible = false
		if h.state.DrawableSize.W != 0 || h.state.DrawableSize.H != 0 {
			if h.renderer != nil {
				if err := h.renderer.Resize(0, 0); err != nil {
					return fmt.Errorf("suspend Win32 WebGPU surface: %w", err)
				}
			}
			h.state.DrawableSize = engine.Size{}
			h.events = append(h.events, engine.Event{Kind: engine.EventWindowResized, Window: h.state})
		}
		return nil
	}
	h.state.Visible = true
	if width == int(h.state.DrawableSize.W) && height == int(h.state.DrawableSize.H) {
		return nil
	}
	if h.renderer != nil {
		if err := h.renderer.Resize(width, height); err != nil {
			return fmt.Errorf("resize Win32 WebGPU surface: %w", err)
		}
	}
	h.state.DrawableSize = engine.Size{W: float64(width), H: float64(height)}
	h.state.Scale = float64(width) / h.config.Viewport.W
	h.events = append(h.events, engine.Event{Kind: engine.EventWindowResized, Window: h.state})
	return nil
}

func (h *win32Host) requestClose() {
	if h.state.CloseRequested {
		return
	}
	h.state.CloseRequested = true
	h.events = append(h.events, engine.Event{Kind: engine.EventCloseRequested, Window: h.state})
}

func (h *win32Host) setFocus(value bool) {
	if h.state.Focused == value {
		return
	}
	h.state.Focused = value
	h.events = append(h.events, engine.Event{Kind: engine.EventFocusChanged, Focused: value})
}

func (h *win32Host) appendKey(value, lparam uintptr, pressed bool) {
	if key, ok := win32KeyEvent(value, lparam); ok {
		h.events = append(h.events, engine.Event{Kind: engine.EventKey, Key: key, Pressed: pressed})
	}
}

func (h *win32Host) pollGamepads() {
	if h.inputCapabilities.Gamepad != engine.InputAvailable {
		return
	}
	for id := uint32(0); id < 4; id++ {
		var state win32XInputState
		result, _, _ := win32XInputGetState.Call(uintptr(id), uintptr(unsafe.Pointer(&state)))
		if result != 0 {
			if _, connected := h.gamepads[id]; connected {
				h.events = append(h.events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: id, Connected: false, GamepadMapping: engine.GamepadMappingStandard})
				delete(h.gamepads, id)
			}
			continue
		}
		current := win32GamepadFromXInput(state.Gamepad)
		previous, connected := h.gamepads[id]
		if !connected {
			h.events = append(h.events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: id, Connected: true, GamepadMapping: engine.GamepadMappingStandard})
		}
		h.appendGamepadChanges(id, previous, current, connected)
		h.gamepads[id] = current
	}
}

func win32GamepadFromXInput(source win32XInputGamepad) win32Gamepad {
	buttons := func(mask uint16) float64 {
		if source.Buttons&mask != 0 {
			return 1
		}
		return 0
	}
	return win32Gamepad{
		buttons: [17]float64{
			buttons(0x1000), buttons(0x2000), buttons(0x4000), buttons(0x8000), buttons(0x0100), buttons(0x0200), float64(source.LeftTrigger) / 255, float64(source.RightTrigger) / 255,
			buttons(0x0020), buttons(0x0010), buttons(0x0040), buttons(0x0080), buttons(0x0001), buttons(0x0002), buttons(0x0004), buttons(0x0008), 0,
		},
		axes: [4]float64{win32Axis(source.ThumbLX), -win32Axis(source.ThumbLY), win32Axis(source.ThumbRX), -win32Axis(source.ThumbRY)},
	}
}

func win32Axis(value int16) float64 {
	if value < 0 {
		return float64(value) / 32768
	}
	return float64(value) / 32767
}

func (h *win32Host) appendGamepadChanges(id uint32, previous, current win32Gamepad, connected bool) {
	for index, value := range current.buttons {
		if !connected || math.Abs(value-previous.buttons[index]) > .001 {
			h.events = append(h.events, engine.Event{Kind: engine.EventGamepadButton, DeviceID: id, Button: engine.GamepadButton(index), Value: value, Pressed: value >= .5})
		}
	}
	for index, value := range current.axes {
		if !connected || math.Abs(value-previous.axes[index]) > .001 {
			h.events = append(h.events, engine.Event{Kind: engine.EventGamepadAxis, DeviceID: id, Axis: engine.GamepadAxis(index), Value: value})
		}
	}
}

func (h *win32Host) appendText(value uint16) {
	decoded := rune(value)
	if utf16.IsSurrogate(rune(value)) {
		if value >= 0xd800 && value <= 0xdbff {
			h.pendingHigh = value
			return
		}
		if h.pendingHigh == 0 || value < 0xdc00 || value > 0xdfff {
			h.pendingHigh = 0
			return
		}
		decoded = utf16.DecodeRune(rune(h.pendingHigh), rune(value))
		h.pendingHigh = 0
	}
	if h.pendingHigh != 0 {
		h.pendingHigh = 0
	}
	if decoded >= 0x20 && decoded != 0x7f {
		h.events = append(h.events, engine.Event{Kind: engine.EventText, Text: string(decoded)})
	}
}

func (h *win32Host) appendIMEComposition(flags uintptr) {
	if h.inputCapabilities.Composition != engine.InputAvailable || flags&win32GCSCompStr == 0 {
		return
	}
	context, _, _ := win32ImmGetContext.Call(h.window)
	if context == 0 {
		return
	}
	defer win32ImmReleaseContext.Call(h.window, context)
	length, _, _ := win32ImmGetCompositionStringW.Call(context, win32GCSCompStr, 0, 0)
	if int32(length) < 0 {
		return
	}
	text := ""
	if length > 0 {
		units := make([]uint16, (length+1)/2)
		written, _, _ := win32ImmGetCompositionStringW.Call(context, win32GCSCompStr, uintptr(unsafe.Pointer(&units[0])), length)
		if int32(written) < 0 {
			return
		}
		text = windows.UTF16ToString(units)
	}
	h.preedit = text
	h.events = append(h.events, engine.Event{Kind: engine.EventComposition, Composition: engine.CompositionUpdate, Text: text})
}

func (h *win32Host) appendPointer(message uint32, wparam, lparam uintptr) {
	position := win32PointFromLParam(lparam)
	point := h.logicalPointerPosition(position)
	switch message {
	case win32WMMouseMove:
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerMove, Position: point})
	case win32WMLButtonDown, win32WMLButtonUp:
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: engine.PointerPrimary, Pressed: message == win32WMLButtonDown, Position: point})
	case win32WMRButtonDown, win32WMRButtonUp:
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: engine.PointerSecondary, Pressed: message == win32WMRButtonDown, Position: point})
	case win32WMMButtonDown, win32WMMButtonUp:
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: engine.PointerMiddle, Pressed: message == win32WMMButtonDown, Position: point})
	case win32WMMouseWheel:
		delta := float64(int16(wparam>>16)) / win32WheelDelta
		if delta != 0 {
			h.events = append(h.events, engine.Event{Kind: engine.EventPointerWheel, Scroll: engine.Vec2{Y: delta}})
		}
	}
}

func (h *win32Host) logicalPointerPosition(position win32Point) engine.Vec2 {
	width, height := h.state.DrawableSize.W, h.state.DrawableSize.H
	if width <= 0 || height <= 0 {
		return engine.Vec2{}
	}
	return engine.Vec2{
		X: float64(position.X) * h.config.Viewport.W / width,
		Y: float64(position.Y) * h.config.Viewport.H / height,
	}
}

func (h *win32Host) close() {
	if h == nil {
		return
	}
	if h.renderer != nil {
		h.renderer.Close()
		h.renderer = nil
	}
	if h.cursorHidden {
		win32ShowCursor.Call(1)
		h.cursorHidden = false
	}
	if h.window != 0 {
		unregisterWin32Host(h.window)
		win32DestroyWindow.Call(h.window)
		h.window = 0
	}
}

func win32WindowProc(window uintptr, message uint32, wparam, lparam uintptr) uintptr {
	host := lookupWin32Host(window)
	if host == nil {
		result, _, _ := win32DefWindowProcW.Call(window, uintptr(message), wparam, lparam)
		return result
	}
	switch message {
	case win32WMClose:
		host.requestClose()
		win32DestroyWindow.Call(window)
		return 0
	case win32WMDestroy:
		host.requestClose()
		host.window = 0
		unregisterWin32Host(window)
		return 0
	case win32WMSetFocus:
		host.setFocus(true)
		return 0
	case win32WMKillFocus:
		host.pendingHigh = 0
		host.setFocus(false)
		return 0
	case win32WMSize:
		host.state.Visible = wparam != win32SizeMinimized
		return 0
	case win32WMShowWindow:
		host.state.Visible = wparam != 0
		return 0
	case win32WMDPIChanged:
		if err := host.resizeForDPI(uint16(wparam)); err != nil {
			host.requestClose()
		}
		return 0
	case win32WMSetCursor:
		if uint16(lparam) == win32HTClient && host.cursorHidden {
			return 1
		}
		if uint16(lparam) == win32HTClient && host.cursor != 0 {
			win32SetCursor.Call(host.cursor)
			return 1
		}
	case win32WMKeyDown, win32WMSysKeyDown:
		host.appendKey(wparam, lparam, true)
		return 0
	case win32WMKeyUp, win32WMSysKeyUp:
		host.appendKey(wparam, lparam, false)
		return 0
	case win32WMChar:
		host.appendText(uint16(wparam))
		return 0
	case win32WMIMEStartComposition:
		host.preedit = ""
		host.events = append(host.events, engine.Event{Kind: engine.EventComposition, Composition: engine.CompositionStart})
		return 0
	case win32WMIMEComposition:
		host.appendIMEComposition(lparam)
		return 0
	case win32WMIMEEndComposition:
		host.events = append(host.events, engine.Event{Kind: engine.EventComposition, Composition: engine.CompositionEnd, Text: host.preedit})
		host.preedit = ""
		return 0
	case win32WMMouseMove, win32WMLButtonDown, win32WMLButtonUp, win32WMRButtonDown, win32WMRButtonUp, win32WMMButtonDown, win32WMMButtonUp, win32WMMouseWheel:
		host.appendPointer(message, wparam, lparam)
		return 0
	}
	result, _, _ := win32DefWindowProcW.Call(window, uintptr(message), wparam, lparam)
	return result
}

func (h *win32Host) resizeForDPI(dpi uint16) error {
	if dpi == 0 {
		return nil
	}
	clientWidth := int(math.Round(h.config.Viewport.W * float64(h.config.WindowScale) * float64(dpi) / 96))
	clientHeight := int(math.Round(h.config.Viewport.H * float64(h.config.WindowScale) * float64(dpi) / 96))
	if clientWidth <= 0 || clientHeight <= 0 {
		return fmt.Errorf("resize Win32 window for DPI: scaled client size is invalid")
	}
	windowRect := win32Rect{Right: int32(clientWidth), Bottom: int32(clientHeight)}
	if result, _, callErr := win32AdjustWindowRectEx.Call(uintptr(unsafe.Pointer(&windowRect)), win32WSOverlappedWindow, 0, 0); result == 0 {
		return win32Error("adjust Win32 DPI window rectangle", callErr)
	}
	if result, _, callErr := win32SetWindowPos.Call(h.window, 0, 0, 0, uintptr(windowRect.Right-windowRect.Left), uintptr(windowRect.Bottom-windowRect.Top), win32SWPNoMove|win32SWPNoZOrder|win32SWPNoActivate); result == 0 {
		return win32Error("apply Win32 DPI window rectangle", callErr)
	}
	return nil
}

func registerWin32Host(host *win32Host) {
	win32HostsMu.Lock()
	win32Hosts[host.window] = host
	win32HostsMu.Unlock()
}

func unregisterWin32Host(window uintptr) {
	win32HostsMu.Lock()
	delete(win32Hosts, window)
	win32HostsMu.Unlock()
}

func lookupWin32Host(window uintptr) *win32Host {
	win32HostsMu.RLock()
	host := win32Hosts[window]
	win32HostsMu.RUnlock()
	return host
}

func win32Key(value uintptr) (engine.Key, bool) {
	key, ok := win32VirtualKeys[value]
	return key, ok
}

func win32KeyEvent(virtual, lparam uintptr) (engine.Key, bool) {
	scan := byte(lparam >> 16)
	extended := lparam&(1<<24) != 0
	if virtual == 0x10 {
		if scan == 0x36 {
			return engine.KeyShiftRight, true
		}
		return engine.KeyShiftLeft, true
	}
	if virtual == 0x11 {
		if extended {
			return engine.KeyControlRight, true
		}
		return engine.KeyControlLeft, true
	}
	if virtual == 0x12 {
		if extended {
			return engine.KeyAltRight, true
		}
		return engine.KeyAltLeft, true
	}
	if key, ok := win32ScanKey(scan, extended); ok {
		return key, true
	}
	return win32Key(virtual)
}

func win32ScanKey(scan byte, extended bool) (engine.Key, bool) {
	if extended {
		key, ok := win32ExtendedScanKeys[scan]
		return key, ok
	}
	key, ok := win32PhysicalScanKeys[scan]
	return key, ok
}

var win32VirtualKeys = map[uintptr]engine.Key{
	0x08: engine.KeyBackspace, 0x09: engine.KeyTab, 0x0d: engine.KeyEnter, 0x13: engine.KeyPause, 0x14: engine.KeyCapsLock, 0x1b: engine.KeyEscape, 0x20: engine.KeySpace, 0x21: engine.KeyPageUp, 0x22: engine.KeyPageDown, 0x23: engine.KeyEnd, 0x24: engine.KeyHome, 0x25: engine.KeyArrowLeft, 0x26: engine.KeyArrowUp, 0x27: engine.KeyArrowRight, 0x28: engine.KeyArrowDown, 0x2c: engine.KeyPrintScreen, 0x2d: engine.KeyInsert, 0x2e: engine.KeyDelete,
	0x30: engine.KeyDigit0, 0x31: engine.KeyDigit1, 0x32: engine.KeyDigit2, 0x33: engine.KeyDigit3, 0x34: engine.KeyDigit4, 0x35: engine.KeyDigit5, 0x36: engine.KeyDigit6, 0x37: engine.KeyDigit7, 0x38: engine.KeyDigit8, 0x39: engine.KeyDigit9,
	0x41: engine.KeyA, 0x42: engine.KeyB, 0x43: engine.KeyC, 0x44: engine.KeyD, 0x45: engine.KeyE, 0x46: engine.KeyF, 0x47: engine.KeyG, 0x48: engine.KeyH, 0x49: engine.KeyI, 0x4a: engine.KeyJ, 0x4b: engine.KeyK, 0x4c: engine.KeyL, 0x4d: engine.KeyM, 0x4e: engine.KeyN, 0x4f: engine.KeyO, 0x50: engine.KeyP, 0x51: engine.KeyQ, 0x52: engine.KeyR, 0x53: engine.KeyS, 0x54: engine.KeyT, 0x55: engine.KeyU, 0x56: engine.KeyV, 0x57: engine.KeyW, 0x58: engine.KeyX, 0x59: engine.KeyY, 0x5a: engine.KeyZ,
	0x5b: engine.KeyMetaLeft, 0x5c: engine.KeyMetaRight, 0x5d: engine.KeyContextMenu,
	0x60: engine.KeyNumpad0, 0x61: engine.KeyNumpad1, 0x62: engine.KeyNumpad2, 0x63: engine.KeyNumpad3, 0x64: engine.KeyNumpad4, 0x65: engine.KeyNumpad5, 0x66: engine.KeyNumpad6, 0x67: engine.KeyNumpad7, 0x68: engine.KeyNumpad8, 0x69: engine.KeyNumpad9, 0x6a: engine.KeyNumpadMultiply, 0x6b: engine.KeyNumpadAdd, 0x6d: engine.KeyNumpadSubtract, 0x6e: engine.KeyNumpadDecimal, 0x6f: engine.KeyNumpadDivide,
	0x70: engine.KeyF1, 0x71: engine.KeyF2, 0x72: engine.KeyF3, 0x73: engine.KeyF4, 0x74: engine.KeyF5, 0x75: engine.KeyF6, 0x76: engine.KeyF7, 0x77: engine.KeyF8, 0x78: engine.KeyF9, 0x79: engine.KeyF10, 0x7a: engine.KeyF11, 0x7b: engine.KeyF12, 0x90: engine.KeyNumLock, 0x91: engine.KeyScrollLock,
	0xba: engine.KeySemicolon, 0xbb: engine.KeyEqual, 0xbc: engine.KeyComma, 0xbd: engine.KeyMinus, 0xbe: engine.KeyPeriod, 0xbf: engine.KeySlash, 0xc0: engine.KeyBackquote, 0xdb: engine.KeyBracketLeft, 0xdc: engine.KeyBackslash, 0xdd: engine.KeyBracketRight, 0xde: engine.KeyQuote,
}

var win32PhysicalScanKeys = map[byte]engine.Key{
	0x01: engine.KeyEscape, 0x02: engine.KeyDigit1, 0x03: engine.KeyDigit2, 0x04: engine.KeyDigit3, 0x05: engine.KeyDigit4, 0x06: engine.KeyDigit5, 0x07: engine.KeyDigit6, 0x08: engine.KeyDigit7, 0x09: engine.KeyDigit8, 0x0a: engine.KeyDigit9, 0x0b: engine.KeyDigit0, 0x0c: engine.KeyMinus, 0x0d: engine.KeyEqual, 0x0e: engine.KeyBackspace, 0x0f: engine.KeyTab,
	0x10: engine.KeyQ, 0x11: engine.KeyW, 0x12: engine.KeyE, 0x13: engine.KeyR, 0x14: engine.KeyT, 0x15: engine.KeyY, 0x16: engine.KeyU, 0x17: engine.KeyI, 0x18: engine.KeyO, 0x19: engine.KeyP, 0x1a: engine.KeyBracketLeft, 0x1b: engine.KeyBracketRight, 0x1c: engine.KeyEnter, 0x1d: engine.KeyControlLeft,
	0x1e: engine.KeyA, 0x1f: engine.KeyS, 0x20: engine.KeyD, 0x21: engine.KeyF, 0x22: engine.KeyG, 0x23: engine.KeyH, 0x24: engine.KeyJ, 0x25: engine.KeyK, 0x26: engine.KeyL, 0x27: engine.KeySemicolon, 0x28: engine.KeyQuote, 0x29: engine.KeyBackquote, 0x2a: engine.KeyShiftLeft, 0x2b: engine.KeyBackslash,
	0x2c: engine.KeyZ, 0x2d: engine.KeyX, 0x2e: engine.KeyC, 0x2f: engine.KeyV, 0x30: engine.KeyB, 0x31: engine.KeyN, 0x32: engine.KeyM, 0x33: engine.KeyComma, 0x34: engine.KeyPeriod, 0x35: engine.KeySlash, 0x36: engine.KeyShiftRight, 0x37: engine.KeyNumpadMultiply, 0x38: engine.KeyAltLeft, 0x39: engine.KeySpace, 0x3a: engine.KeyCapsLock,
	0x3b: engine.KeyF1, 0x3c: engine.KeyF2, 0x3d: engine.KeyF3, 0x3e: engine.KeyF4, 0x3f: engine.KeyF5, 0x40: engine.KeyF6, 0x41: engine.KeyF7, 0x42: engine.KeyF8, 0x43: engine.KeyF9, 0x44: engine.KeyF10, 0x45: engine.KeyNumLock, 0x46: engine.KeyScrollLock,
	0x47: engine.KeyNumpad7, 0x48: engine.KeyNumpad8, 0x49: engine.KeyNumpad9, 0x4a: engine.KeyNumpadSubtract, 0x4b: engine.KeyNumpad4, 0x4c: engine.KeyNumpad5, 0x4d: engine.KeyNumpad6, 0x4e: engine.KeyNumpadAdd, 0x4f: engine.KeyNumpad1, 0x50: engine.KeyNumpad2, 0x51: engine.KeyNumpad3, 0x52: engine.KeyNumpad0, 0x53: engine.KeyNumpadDecimal,
	0x56: engine.KeyIntlBackslash, 0x57: engine.KeyF11, 0x58: engine.KeyF12,
}

var win32ExtendedScanKeys = map[byte]engine.Key{
	0x1c: engine.KeyNumpadEnter, 0x1d: engine.KeyControlRight, 0x35: engine.KeyNumpadDivide, 0x38: engine.KeyAltRight, 0x47: engine.KeyHome, 0x48: engine.KeyArrowUp, 0x49: engine.KeyPageUp, 0x4b: engine.KeyArrowLeft, 0x4d: engine.KeyArrowRight, 0x4f: engine.KeyEnd, 0x50: engine.KeyArrowDown, 0x51: engine.KeyPageDown, 0x52: engine.KeyInsert, 0x53: engine.KeyDelete, 0x5b: engine.KeyMetaLeft, 0x5c: engine.KeyMetaRight, 0x5d: engine.KeyContextMenu,
}

func win32CursorID(cursor engine.Cursor) (uintptr, bool) {
	switch cursor {
	case engine.CursorDefault:
		return win32IDCArrow, true
	case engine.CursorPointer:
		return win32IDCHand, true
	case engine.CursorText:
		return win32IDCText, true
	case engine.CursorCrosshair:
		return win32IDCCross, true
	default:
		return 0, false
	}
}

func win32PointFromLParam(value uintptr) win32Point {
	return win32Point{X: int32(int16(value)), Y: int32(int16(value >> 16))}
}

func win32Error(operation string, err error) error {
	if err == nil || err == windows.ERROR_SUCCESS {
		return fmt.Errorf("%s: Win32 call failed", operation)
	}
	return fmt.Errorf("%s: %w", operation, err)
}

func maxInt() int { return int(^uint(0) >> 1) }
