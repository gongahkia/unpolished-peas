//go:build darwin

package platform

import (
	"fmt"
	"math"
	"runtime"
	"time"
	"unicode/utf16"
	"unsafe"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render/webgpu"
)

const (
	macApplicationActivationPolicyRegular = 0
	macWindowStyleMaskTitled              = 1 << 0
	macWindowStyleMaskClosable            = 1 << 1
	macWindowStyleMaskMiniaturizable      = 1 << 2
	macWindowStyleMaskResizable           = 1 << 3
	macBackingStoreBuffered               = 2

	macEventLeftMouseDown  = 1
	macEventLeftMouseUp    = 2
	macEventRightMouseDown = 3
	macEventRightMouseUp   = 4
	macEventMouseMoved     = 5
	macEventLeftMouseDrag  = 6
	macEventRightMouseDrag = 7
	macEventKeyDown        = 10
	macEventKeyUp          = 11
	macEventFlagsChanged   = 12
	macEventScrollWheel    = 22
	macEventOtherMouseDown = 25
	macEventOtherMouseUp   = 26
	macEventOtherMouseDrag = 27

	macShiftModifier   = 1 << 17
	macControlModifier = 1 << 18
	macOptionModifier  = 1 << 19
	macCommandModifier = 1 << 20
)

// Run starts the AppKit host from one locked OS thread. The host owns the
// NSWindow, CAMetalLayer, event pump, and private WebGPU renderer.
func Run(config engine.Config, app engine.Application) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	host, err := newMacHost(config)
	if err != nil {
		return err
	}
	defer host.close()
	return engine.RunWithHost(config, app, host)
}

type macHost struct {
	config   engine.Config
	runtime  *macRuntime
	app      uintptr
	window   uintptr
	view     uintptr
	layer    uintptr
	renderer *webgpu.Renderer

	state  engine.WindowState
	events []engine.Event
	frame  uint64
	start  time.Time
	last   time.Time
	timing engine.FrameTiming

	pendingHigh  uint16
	cursorHidden bool
}

func newMacHost(config engine.Config) (*macHost, error) {
	if math.IsNaN(config.Viewport.W) || math.IsInf(config.Viewport.W, 0) || math.IsNaN(config.Viewport.H) || math.IsInf(config.Viewport.H, 0) || config.Viewport.W <= 0 || config.Viewport.H <= 0 || config.WindowScale <= 0 {
		return nil, fmt.Errorf("create macOS host: configuration has an invalid viewport or window scale")
	}
	if err := config.Actions.Validate(); err != nil {
		return nil, fmt.Errorf("create macOS host: %w", err)
	}
	runtime, err := newMacRuntime()
	if err != nil {
		return nil, err
	}
	host := &macHost{config: config, runtime: runtime}
	cleanupRuntime := true
	defer func() {
		if cleanupRuntime {
			host.close()
		}
	}()
	threadClass, err := runtime.class("NSThread")
	if err != nil {
		return nil, err
	}
	isMainThread, err := runtime.bool(threadClass, "isMainThread")
	if err != nil {
		return nil, fmt.Errorf("verify macOS main thread: %w", err)
	}
	if !isMainThread {
		return nil, fmt.Errorf("create macOS host: Run must be called from the process main thread")
	}
	pool, err := macAutoreleasePool(runtime)
	if err != nil {
		return nil, err
	}
	defer runtime.void(pool, "drain")

	logicalWidth, logicalHeight := int(config.Viewport.W), int(config.Viewport.H)
	if float64(logicalWidth) != config.Viewport.W || float64(logicalHeight) != config.Viewport.H {
		return nil, fmt.Errorf("create macOS host: viewport dimensions must be integral pixels")
	}
	if logicalWidth > maxInt()/config.WindowScale || logicalHeight > maxInt()/config.WindowScale {
		return nil, fmt.Errorf("create macOS host: presentation size is outside the supported range")
	}
	physicalWidth, physicalHeight := logicalWidth*config.WindowScale, logicalHeight*config.WindowScale
	if uint64(physicalWidth) > uint64(^uint32(0)) || uint64(physicalHeight) > uint64(^uint32(0)) {
		return nil, fmt.Errorf("create macOS host: presentation size exceeds WebGPU's uint32 surface extent")
	}
	appClass, err := runtime.class("NSApplication")
	if err != nil {
		return nil, err
	}
	app, err := runtime.id(appClass, "sharedApplication")
	if err != nil {
		return nil, err
	}
	host.app = app
	if err := runtime.void(app, "setActivationPolicy:", macInt64(macApplicationActivationPolicyRegular)); err != nil {
		return nil, err
	}
	if err := runtime.void(app, "finishLaunching"); err != nil {
		return nil, err
	}
	windowClass, err := runtime.class("NSWindow")
	if err != nil {
		return nil, err
	}
	window, err := runtime.id(windowClass, "alloc")
	if err != nil {
		return nil, err
	}
	host.window = window
	frame := macRect{Size: macSize{Width: float64(physicalWidth), Height: float64(physicalHeight)}}
	window, err = runtime.id(window, "initWithContentRect:styleMask:backing:defer:", macRectArgument(frame), macUint64(macWindowStyleMaskTitled|macWindowStyleMaskClosable|macWindowStyleMaskMiniaturizable|macWindowStyleMaskResizable), macUint64(macBackingStoreBuffered), macBool(false))
	if err != nil || window == 0 {
		if err == nil {
			err = fmt.Errorf("AppKit returned a null window")
		}
		return nil, fmt.Errorf("create macOS window: %w", err)
	}
	host.window = window
	title, err := macNSString(runtime, config.Title)
	if err != nil {
		return nil, err
	}
	if err := runtime.void(window, "setTitle:", macPointer(title)); err != nil {
		return nil, err
	}
	viewClass, err := runtime.class("NSView")
	if err != nil {
		return nil, err
	}
	view, err := runtime.id(viewClass, "alloc")
	if err != nil {
		return nil, err
	}
	host.view = view
	view, err = runtime.id(view, "initWithFrame:", macRectArgument(frame))
	if err != nil || view == 0 {
		if err == nil {
			err = fmt.Errorf("AppKit returned a null content view")
		}
		return nil, fmt.Errorf("create macOS content view: %w", err)
	}
	host.view = view
	if err := runtime.void(view, "setWantsLayer:", macBool(true)); err != nil {
		return nil, err
	}
	layerClass, err := runtime.class("CAMetalLayer")
	if err != nil {
		return nil, err
	}
	layer, err := runtime.id(layerClass, "alloc")
	if err != nil {
		return nil, err
	}
	host.layer = layer
	layer, err = runtime.id(layer, "init")
	if err != nil || layer == 0 {
		if err == nil {
			err = fmt.Errorf("QuartzCore returned a null Metal layer")
		}
		return nil, fmt.Errorf("create macOS Metal layer: %w", err)
	}
	host.layer = layer
	for _, call := range []struct {
		receiver  uintptr
		selector  string
		arguments []macArgument
	}{
		{view, "setLayer:", []macArgument{macPointer(layer)}},
		{window, "setContentView:", []macArgument{macPointer(view)}},
		{window, "setAcceptsMouseMovedEvents:", []macArgument{macBool(true)}},
		{window, "center", nil},
		{window, "makeKeyAndOrderFront:", []macArgument{macPointer(0)}},
		{app, "activateIgnoringOtherApps:", []macArgument{macBool(true)}},
	} {
		if err := runtime.void(call.receiver, call.selector, call.arguments...); err != nil {
			return nil, err
		}
	}
	now := time.Now()
	host.state = engine.WindowState{Title: config.Title, LogicalSize: config.Viewport, Focused: true, Visible: true}
	host.start, host.last = now, now
	if err := host.refreshDrawable(); err != nil {
		return nil, err
	}
	host.events = nil
	renderer, err := webgpu.NewMetalLayer(layer, int(host.state.DrawableSize.W), int(host.state.DrawableSize.H))
	if err != nil {
		return nil, fmt.Errorf("create macOS WebGPU renderer: %w", err)
	}
	host.renderer = renderer
	if err := renderer.SetLogicalSize(logicalWidth, logicalHeight); err != nil {
		return nil, err
	}
	cleanupRuntime = false
	return host, nil
}

func (h *macHost) Context() engine.HostContext {
	return engine.HostContext{Window: h, Clock: h, Events: h}
}

func (*macHost) InputCapabilities() engine.InputCapabilities {
	return engine.InputCapabilities{Keyboard: engine.InputAvailable}
}

func (h *macHost) Run(appRuntime *engine.Runtime) error {
	if appRuntime == nil {
		return fmt.Errorf("run macOS host: runtime must not be nil")
	}
	next := time.Now()
	for !h.state.CloseRequested {
		pool, err := macAutoreleasePool(h.runtime)
		if err != nil {
			return err
		}
		err = h.pollNative()
		if err == nil {
			err = h.refreshDrawable()
		}
		if err == nil && !h.state.Visible {
			now := time.Now()
			h.last, next = now, now
		}
		if err == nil && h.state.Visible && !h.state.CloseRequested {
			now := h.Now()
			h.frame++
			h.timing = engine.FrameTiming{Frame: h.frame, Elapsed: now.Sub(h.start), Delta: now.Sub(h.last)}
			h.last = now
			err = appRuntime.Update(appRuntime.SampleInput(h.PollEvents()))
			if err == nil {
				err = appRuntime.Draw(h.renderer)
			}
		}
		poolErr := h.runtime.void(pool, "drain")
		if err != nil {
			return err
		}
		if poolErr != nil {
			return poolErr
		}
		if h.state.CloseRequested {
			break
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

func (h *macHost) State() engine.WindowState { return h.state }

func (h *macHost) SetTitle(value string) error {
	title, err := macNSString(h.runtime, value)
	if err != nil {
		return err
	}
	if err := h.runtime.void(h.window, "setTitle:", macPointer(title)); err != nil {
		return fmt.Errorf("set macOS title: %w", err)
	}
	h.state.Title = value
	return nil
}

func (h *macHost) SetCursor(cursor engine.Cursor) error {
	cursorClass, err := h.runtime.class("NSCursor")
	if err != nil {
		return err
	}
	if h.cursorHidden && cursor != engine.CursorHidden {
		if err := h.runtime.void(cursorClass, "unhide"); err != nil {
			return fmt.Errorf("restore macOS cursor: %w", err)
		}
		h.cursorHidden = false
	}
	if cursor == engine.CursorHidden {
		if !h.cursorHidden {
			if err := h.runtime.void(cursorClass, "hide"); err != nil {
				return fmt.Errorf("hide macOS cursor: %w", err)
			}
			h.cursorHidden = true
		}
		return nil
	}
	selector, ok := macCursorSelector(cursor)
	if !ok {
		return fmt.Errorf("set macOS cursor: unsupported cursor %d", cursor)
	}
	value, err := h.runtime.id(cursorClass, selector)
	if err != nil {
		return fmt.Errorf("load macOS cursor: %w", err)
	}
	if err := h.runtime.void(value, "set"); err != nil {
		return fmt.Errorf("set macOS cursor: %w", err)
	}
	return nil
}

func (h *macHost) ReadClipboard() (string, error) {
	pasteboardClass, err := h.runtime.class("NSPasteboard")
	if err != nil {
		return "", err
	}
	pasteboard, err := h.runtime.id(pasteboardClass, "generalPasteboard")
	if err != nil || pasteboard == 0 {
		if err == nil {
			err = fmt.Errorf("general pasteboard is unavailable")
		}
		return "", fmt.Errorf("read macOS clipboard: %w", err)
	}
	typeName, err := macNSString(h.runtime, "public.utf8-plain-text")
	if err != nil {
		return "", err
	}
	value, err := h.runtime.id(pasteboard, "stringForType:", macPointer(typeName))
	if err != nil {
		return "", fmt.Errorf("read macOS clipboard: %w", err)
	}
	if value == 0 {
		return "", nil
	}
	return macGoString(h.runtime, value)
}

func (h *macHost) WriteClipboard(value string) error {
	pasteboardClass, err := h.runtime.class("NSPasteboard")
	if err != nil {
		return err
	}
	pasteboard, err := h.runtime.id(pasteboardClass, "generalPasteboard")
	if err != nil || pasteboard == 0 {
		if err == nil {
			err = fmt.Errorf("general pasteboard is unavailable")
		}
		return fmt.Errorf("write macOS clipboard: %w", err)
	}
	text, err := macNSString(h.runtime, value)
	if err != nil {
		return err
	}
	typeName, err := macNSString(h.runtime, "public.utf8-plain-text")
	if err != nil {
		return err
	}
	if changed, err := h.runtime.int64(pasteboard, "clearContents"); err != nil || changed < 0 {
		if err == nil {
			err = fmt.Errorf("pasteboard rejected the operation")
		}
		return fmt.Errorf("clear macOS clipboard: %w", err)
	}
	written, err := h.runtime.bool(pasteboard, "setString:forType:", macPointer(text), macPointer(typeName))
	if err != nil || !written {
		if err == nil {
			err = fmt.Errorf("pasteboard rejected text")
		}
		return fmt.Errorf("write macOS clipboard: %w", err)
	}
	return nil
}

func (h *macHost) Now() time.Time             { return time.Now() }
func (h *macHost) Timing() engine.FrameTiming { return h.timing }

func (h *macHost) PollEvents() []engine.Event {
	events := append([]engine.Event(nil), h.events...)
	h.events = h.events[:0]
	return events
}

func (h *macHost) pollNative() error {
	mode, err := macNSString(h.runtime, "kCFRunLoopDefaultMode")
	if err != nil {
		return err
	}
	for {
		event, err := h.runtime.id(h.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", macUint64(^uint64(0)), macPointer(0), macPointer(mode), macBool(true))
		if err != nil {
			return fmt.Errorf("poll macOS events: %w", err)
		}
		if event == 0 {
			return nil
		}
		if err := h.appendEvent(event); err != nil {
			return err
		}
		if err := h.runtime.void(h.app, "sendEvent:", macPointer(event)); err != nil {
			return fmt.Errorf("dispatch macOS event: %w", err)
		}
	}
}

func (h *macHost) refreshDrawable() error {
	visible, err := h.runtime.bool(h.window, "isVisible")
	if err != nil {
		return fmt.Errorf("read macOS window visibility: %w", err)
	}
	miniaturized, err := h.runtime.bool(h.window, "isMiniaturized")
	if err != nil {
		return fmt.Errorf("read macOS window state: %w", err)
	}
	h.state.Visible = visible && !miniaturized
	focused, err := h.runtime.bool(h.window, "isKeyWindow")
	if err != nil {
		return fmt.Errorf("read macOS window focus: %w", err)
	}
	h.setFocus(h.state.Visible && focused)
	if !h.state.Visible {
		if h.state.DrawableSize.W != 0 || h.state.DrawableSize.H != 0 {
			if h.renderer != nil {
				if err := h.renderer.Resize(0, 0); err != nil {
					return fmt.Errorf("suspend macOS WebGPU surface: %w", err)
				}
			}
			h.state.DrawableSize = engine.Size{}
			h.events = append(h.events, engine.Event{Kind: engine.EventWindowResized, Window: h.state})
		}
		if !visible && !miniaturized {
			h.requestClose()
		}
		return nil
	}
	bounds, err := h.runtime.rect(h.view, "bounds")
	if err != nil {
		return fmt.Errorf("read macOS content bounds: %w", err)
	}
	scale, err := h.runtime.double(h.window, "backingScaleFactor")
	if err != nil {
		return fmt.Errorf("read macOS backing scale: %w", err)
	}
	if scale <= 0 || math.IsNaN(scale) || math.IsInf(scale, 0) {
		scale = 1
	}
	width, height := int(math.Round(bounds.Size.Width*scale)), int(math.Round(bounds.Size.Height*scale))
	if width < 0 || height < 0 {
		return fmt.Errorf("resize macOS drawable: content view reported a negative size")
	}
	if width == int(h.state.DrawableSize.W) && height == int(h.state.DrawableSize.H) {
		return nil
	}
	if err := h.runtime.void(h.layer, "setContentsScale:", macDouble(scale)); err != nil {
		return fmt.Errorf("set macOS Metal scale: %w", err)
	}
	if err := h.runtime.void(h.layer, "setDrawableSize:", macSizeArgument(macSize{Width: float64(width), Height: float64(height)})); err != nil {
		return fmt.Errorf("set macOS Metal drawable size: %w", err)
	}
	if h.renderer != nil {
		if err := h.renderer.Resize(width, height); err != nil {
			return fmt.Errorf("resize macOS WebGPU surface: %w", err)
		}
	}
	h.state.DrawableSize = engine.Size{W: float64(width), H: float64(height)}
	if width > 0 {
		h.state.Scale = float64(width) / h.config.Viewport.W
	}
	h.events = append(h.events, engine.Event{Kind: engine.EventWindowResized, Window: h.state})
	return nil
}

func (h *macHost) appendEvent(event uintptr) error {
	eventType, err := h.runtime.uint64(event, "type")
	if err != nil {
		return err
	}
	switch eventType {
	case macEventKeyDown:
		if err := h.appendKey(event, true); err != nil {
			return err
		}
		return h.appendEventText(event)
	case macEventKeyUp:
		return h.appendKey(event, false)
	case macEventFlagsChanged:
		code, err := h.runtime.uint16(event, "keyCode")
		if err != nil {
			return err
		}
		flags, err := h.runtime.uint64(event, "modifierFlags")
		if err != nil {
			return err
		}
		if key, ok := macKey(code); ok {
			if pressed, modifier := macModifierPressed(key, flags); modifier {
				h.events = append(h.events, engine.Event{Kind: engine.EventKey, Key: key, Pressed: pressed})
			}
		}
	case macEventMouseMoved, macEventLeftMouseDrag, macEventRightMouseDrag, macEventOtherMouseDrag:
		point, err := h.pointerPosition(event)
		if err != nil {
			return err
		}
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerMove, Position: point})
	case macEventLeftMouseDown, macEventLeftMouseUp, macEventRightMouseDown, macEventRightMouseUp, macEventOtherMouseDown, macEventOtherMouseUp:
		number, err := h.runtime.uint64(event, "buttonNumber")
		if err != nil {
			return err
		}
		button, ok := macPointerButton(eventType, number)
		if !ok {
			return nil
		}
		point, err := h.pointerPosition(event)
		if err != nil {
			return err
		}
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: button, Pressed: eventType == macEventLeftMouseDown || eventType == macEventRightMouseDown || eventType == macEventOtherMouseDown, Position: point})
	case macEventScrollWheel:
		x, err := h.runtime.double(event, "scrollingDeltaX")
		if err != nil {
			return err
		}
		y, err := h.runtime.double(event, "scrollingDeltaY")
		if err != nil {
			return err
		}
		if x != 0 || y != 0 {
			h.events = append(h.events, engine.Event{Kind: engine.EventPointerWheel, Scroll: engine.Vec2{X: x, Y: y}})
		}
	}
	return nil
}

func (h *macHost) appendKey(event uintptr, pressed bool) error {
	code, err := h.runtime.uint16(event, "keyCode")
	if err != nil {
		return err
	}
	if key, ok := macKey(code); ok {
		h.events = append(h.events, engine.Event{Kind: engine.EventKey, Key: key, Pressed: pressed})
	}
	return nil
}

func (h *macHost) appendEventText(event uintptr) error {
	text, err := h.runtime.id(event, "characters")
	if err != nil {
		return err
	}
	length, err := h.runtime.uint64(text, "length")
	if err != nil {
		return err
	}
	for index := uint64(0); index < length; index++ {
		value, err := h.runtime.uint16(text, "characterAtIndex:", macUint64(index))
		if err != nil {
			return err
		}
		h.appendText(value)
	}
	return nil
}

func (h *macHost) appendText(value uint16) {
	decoded := rune(value)
	if value >= 0xd800 && value <= 0xdbff {
		h.pendingHigh = value
		return
	}
	if value >= 0xdc00 && value <= 0xdfff {
		if h.pendingHigh == 0 {
			return
		}
		decoded = utf16.DecodeRune(rune(h.pendingHigh), rune(value))
	}
	h.pendingHigh = 0
	if decoded >= 0x20 && decoded != 0x7f {
		h.events = append(h.events, engine.Event{Kind: engine.EventText, Text: string(decoded)})
	}
}

func (h *macHost) pointerPosition(event uintptr) (engine.Vec2, error) {
	point, err := h.runtime.callPoint(event, "locationInWindow")
	if err != nil {
		return engine.Vec2{}, err
	}
	bounds, err := h.runtime.rect(h.view, "bounds")
	if err != nil {
		return engine.Vec2{}, err
	}
	if bounds.Size.Width <= 0 || bounds.Size.Height <= 0 {
		return engine.Vec2{}, nil
	}
	return engine.Vec2{X: point.X / (bounds.Size.Width / h.config.Viewport.W), Y: (bounds.Size.Height - point.Y) / (bounds.Size.Height / h.config.Viewport.H)}, nil
}

func (h *macHost) requestClose() {
	if h.state.CloseRequested {
		return
	}
	h.state.CloseRequested = true
	h.events = append(h.events, engine.Event{Kind: engine.EventCloseRequested, Window: h.state})
}

func (h *macHost) setFocus(value bool) {
	if h.state.Focused == value {
		return
	}
	h.state.Focused = value
	h.events = append(h.events, engine.Event{Kind: engine.EventFocusChanged, Focused: value})
}

func (h *macHost) close() {
	if h == nil {
		return
	}
	if h.cursorHidden && h.runtime != nil {
		if cursorClass, err := h.runtime.class("NSCursor"); err == nil {
			_ = h.runtime.void(cursorClass, "unhide")
		}
		h.cursorHidden = false
	}
	if h.renderer != nil {
		h.renderer.Close()
		h.renderer = nil
	}
	if h.window != 0 && h.runtime != nil {
		_ = h.runtime.void(h.window, "close")
		_ = h.runtime.void(h.window, "release")
		h.window = 0
	}
	if h.view != 0 && h.runtime != nil {
		_ = h.runtime.void(h.view, "release")
		h.view = 0
	}
	if h.layer != 0 && h.runtime != nil {
		_ = h.runtime.void(h.layer, "release")
		h.layer = 0
	}
	if h.runtime != nil {
		h.runtime.close()
		h.runtime = nil
	}
}

func macAutoreleasePool(runtime *macRuntime) (uintptr, error) {
	poolClass, err := runtime.class("NSAutoreleasePool")
	if err != nil {
		return 0, err
	}
	pool, err := runtime.id(poolClass, "new")
	if err != nil || pool == 0 {
		if err == nil {
			err = fmt.Errorf("Objective-C returned a null pool")
		}
		return 0, fmt.Errorf("create macOS autorelease pool: %w", err)
	}
	return pool, nil
}

func macNSString(runtime *macRuntime, value string) (uintptr, error) {
	valueClass, err := runtime.class("NSString")
	if err != nil {
		return 0, err
	}
	argument, err := macUTF8(value)
	if err != nil {
		return 0, fmt.Errorf("encode macOS string: %w", err)
	}
	result, err := runtime.id(valueClass, "stringWithUTF8String:", argument)
	if err != nil || result == 0 {
		if err == nil {
			err = fmt.Errorf("NSString returned null")
		}
		return 0, fmt.Errorf("encode macOS string: %w", err)
	}
	return result, nil
}

func macGoString(runtime *macRuntime, value uintptr) (string, error) {
	pointer, err := runtime.pointer(value, "UTF8String")
	if err != nil {
		return "", fmt.Errorf("decode macOS string: %w", err)
	}
	if pointer == nil {
		return "", nil
	}
	length, err := runtime.uint64(value, "lengthOfBytesUsingEncoding:", macUint64(4))
	if err != nil {
		return "", fmt.Errorf("decode macOS string length: %w", err)
	}
	if length > uint64(maxInt()) {
		return "", fmt.Errorf("decode macOS string: UTF-8 data is too large")
	}
	return string(unsafe.Slice((*byte)(pointer), int(length))), nil
}

func maxInt() int { return int(^uint(0) >> 1) }

func macKey(code uint16) (engine.Key, bool) { key, ok := macPhysicalKeys[code]; return key, ok }

var macPhysicalKeys = map[uint16]engine.Key{
	0: engine.KeyA, 1: engine.KeyS, 2: engine.KeyD, 3: engine.KeyF, 4: engine.KeyH, 5: engine.KeyG, 6: engine.KeyZ, 7: engine.KeyX, 8: engine.KeyC, 9: engine.KeyV, 11: engine.KeyB, 12: engine.KeyQ, 13: engine.KeyW, 14: engine.KeyE, 15: engine.KeyR, 16: engine.KeyY, 17: engine.KeyT, 31: engine.KeyO, 32: engine.KeyU, 34: engine.KeyI, 35: engine.KeyP, 37: engine.KeyL, 38: engine.KeyJ, 40: engine.KeyK, 45: engine.KeyN, 46: engine.KeyM,
	18: engine.KeyDigit1, 19: engine.KeyDigit2, 20: engine.KeyDigit3, 21: engine.KeyDigit4, 22: engine.KeyDigit6, 23: engine.KeyDigit5, 24: engine.KeyEqual, 25: engine.KeyDigit9, 26: engine.KeyDigit7, 27: engine.KeyMinus, 28: engine.KeyDigit8, 29: engine.KeyDigit0,
	30: engine.KeyBracketRight, 33: engine.KeyBracketLeft, 39: engine.KeyQuote, 41: engine.KeySemicolon, 42: engine.KeyBackslash, 43: engine.KeyComma, 44: engine.KeySlash, 47: engine.KeyPeriod, 50: engine.KeyBackquote,
	36: engine.KeyEnter, 48: engine.KeyTab, 49: engine.KeySpace, 51: engine.KeyBackspace, 53: engine.KeyEscape, 54: engine.KeyMetaRight, 55: engine.KeyMetaLeft, 56: engine.KeyShiftLeft, 57: engine.KeyCapsLock, 58: engine.KeyAltLeft, 59: engine.KeyControlLeft, 60: engine.KeyShiftRight, 61: engine.KeyAltRight, 62: engine.KeyControlRight,
	65: engine.KeyNumpadDecimal, 67: engine.KeyNumpadMultiply, 69: engine.KeyNumpadAdd, 71: engine.KeyNumLock, 75: engine.KeyNumpadDivide, 76: engine.KeyNumpadEnter, 78: engine.KeyNumpadSubtract, 81: engine.KeyNumpadEqual, 82: engine.KeyNumpad0, 83: engine.KeyNumpad1, 84: engine.KeyNumpad2, 85: engine.KeyNumpad3, 86: engine.KeyNumpad4, 87: engine.KeyNumpad5, 88: engine.KeyNumpad6, 89: engine.KeyNumpad7, 91: engine.KeyNumpad8, 92: engine.KeyNumpad9,
	96: engine.KeyF5, 97: engine.KeyF6, 98: engine.KeyF7, 99: engine.KeyF3, 100: engine.KeyF8, 101: engine.KeyF9, 103: engine.KeyF11, 109: engine.KeyF10, 110: engine.KeyContextMenu, 111: engine.KeyF12, 114: engine.KeyHelp, 115: engine.KeyHome, 116: engine.KeyPageUp, 117: engine.KeyDelete, 118: engine.KeyF4, 119: engine.KeyEnd, 120: engine.KeyF2, 121: engine.KeyPageDown, 122: engine.KeyF1, 123: engine.KeyArrowLeft, 124: engine.KeyArrowRight, 125: engine.KeyArrowDown, 126: engine.KeyArrowUp,
}

func macModifierPressed(key engine.Key, flags uint64) (bool, bool) {
	switch key {
	case engine.KeyShiftLeft, engine.KeyShiftRight:
		return flags&macShiftModifier != 0, true
	case engine.KeyControlLeft, engine.KeyControlRight:
		return flags&macControlModifier != 0, true
	case engine.KeyAltLeft, engine.KeyAltRight:
		return flags&macOptionModifier != 0, true
	case engine.KeyMetaLeft, engine.KeyMetaRight:
		return flags&macCommandModifier != 0, true
	default:
		return false, false
	}
}

func macPointerButton(eventType, number uint64) (engine.PointerButton, bool) {
	switch eventType {
	case macEventLeftMouseDown, macEventLeftMouseUp:
		return engine.PointerPrimary, true
	case macEventRightMouseDown, macEventRightMouseUp:
		return engine.PointerSecondary, true
	case macEventOtherMouseDown, macEventOtherMouseUp:
		if number == 2 {
			return engine.PointerMiddle, true
		}
	}
	return 0, false
}

func macCursorSelector(cursor engine.Cursor) (string, bool) {
	switch cursor {
	case engine.CursorDefault:
		return "arrowCursor", true
	case engine.CursorPointer:
		return "pointingHandCursor", true
	case engine.CursorText:
		return "IBeamCursor", true
	case engine.CursorCrosshair:
		return "crosshairCursor", true
	default:
		return "", false
	}
}
