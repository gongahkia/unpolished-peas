//go:build js && wasm

package platform

import (
	"fmt"
	"math"
	"syscall/js"
	"time"
	"unicode/utf8"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render/webgpu"
)

// Run starts the browser canvas host. It reports unavailable WebGPU as a
// contextual startup error; it does not select a Canvas or WebGL fallback.
func Run(config engine.Config, app engine.Application) error {
	host, err := newBrowserHost(config)
	if err != nil {
		return err
	}
	return engine.RunWithHost(config, app, host)
}

type browserHost struct {
	config            engine.Config
	document          js.Value
	window            js.Value
	canvas            js.Value
	textInput         js.Value
	renderer          *webgpu.Renderer
	inputCapabilities engine.InputCapabilities
	gamepads          map[uint32]browserGamepad
	clipboardNext     engine.ClipboardRequestID
	clipboard         []engine.ClipboardCompletion
	clipboardRequests []*browserClipboardRequest

	state  engine.WindowState
	events []engine.Event
	start  time.Time
	last   time.Time
	frame  uint64
	timing engine.FrameTiming

	listeners []browserListener
	raf       js.Func
	rafReady  bool
	runtime   *engine.Runtime
	done      chan error
	stopped   bool
}

type browserListener struct {
	target   js.Value
	name     string
	callback js.Func
}

type browserClipboardRequest struct {
	id        engine.ClipboardRequestID
	operation engine.ClipboardOperation
	resolve   js.Func
	reject    js.Func
	settled   bool
}

func newBrowserHost(config engine.Config) (*browserHost, error) {
	if config.Viewport.W <= 0 || config.Viewport.H <= 0 || config.WindowScale <= 0 {
		return nil, fmt.Errorf("create browser host: configuration has an invalid viewport or window scale")
	}
	logicalWidth, logicalHeight := int(config.Viewport.W), int(config.Viewport.H)
	if float64(logicalWidth) != config.Viewport.W || float64(logicalHeight) != config.Viewport.H {
		return nil, fmt.Errorf("create browser host: viewport dimensions must be integral pixels")
	}
	document := js.Global().Get("document")
	window := js.Global().Get("window")
	if document.IsNull() || document.IsUndefined() || window.IsNull() || window.IsUndefined() {
		return nil, fmt.Errorf("create browser host: DOM window and document are required")
	}
	canvas := document.Call("querySelector", "canvas")
	if canvas.IsNull() || canvas.IsUndefined() {
		canvas = document.Call("createElement", "canvas")
		document.Get("body").Call("appendChild", canvas)
	}
	canvas.Set("tabIndex", 0)
	textInput := document.Call("createElement", "textarea")
	textInput.Set("tabIndex", -1)
	textInput.Call("setAttribute", "aria-label", "72 text input")
	style := textInput.Get("style")
	style.Set("position", "fixed")
	style.Set("left", "-10000px")
	style.Set("top", "0")
	style.Set("width", "1px")
	style.Set("height", "1px")
	style.Set("opacity", "0")
	document.Get("body").Call("appendChild", textInput)
	if config.Title != "" {
		document.Set("title", config.Title)
	}
	cssWidth, cssHeight := logicalWidth*config.WindowScale, logicalHeight*config.WindowScale
	canvas.Get("style").Set("width", fmt.Sprintf("%dpx", cssWidth))
	canvas.Get("style").Set("height", "auto")
	canvas.Get("style").Set("maxWidth", "100%")
	dpr := devicePixelRatio(window)
	physicalWidth, physicalHeight := scaledCanvasSize(cssWidth, cssHeight, dpr)
	canvas.Set("width", physicalWidth)
	canvas.Set("height", physicalHeight)
	renderer, err := webgpu.NewCanvas(canvas, physicalWidth, physicalHeight)
	if err != nil {
		return nil, fmt.Errorf("create browser WebGPU renderer: %w", err)
	}
	if err := renderer.SetLogicalSize(logicalWidth, logicalHeight); err != nil {
		renderer.Close()
		return nil, err
	}
	now := time.Now()
	visible := !document.Get("hidden").Bool()
	host := &browserHost{
		config: config, document: document, window: window, canvas: canvas, textInput: textInput, renderer: renderer, start: now, last: now,
		inputCapabilities: browserCapabilities(window), gamepads: make(map[uint32]browserGamepad),
		state: engine.WindowState{Title: config.Title, LogicalSize: engine.Size{W: config.Viewport.W, H: config.Viewport.H}, DrawableSize: engine.Size{W: float64(physicalWidth), H: float64(physicalHeight)}, Scale: float64(config.WindowScale) * dpr, Focused: visible && documentHasFocus(document), Visible: visible},
		done:  make(chan error, 1),
	}
	host.listen()
	return host, nil
}

func (h *browserHost) Context() engine.HostContext {
	return engine.HostContext{Window: h, Clock: h, Events: h}
}

func (h *browserHost) Run(runtime *engine.Runtime) error {
	if runtime == nil {
		return fmt.Errorf("run browser host: runtime must not be nil")
	}
	if h.runtime != nil {
		return fmt.Errorf("run browser host: host is already running")
	}
	h.runtime = runtime
	h.raf = js.FuncOf(func(_ js.Value, _ []js.Value) any {
		h.drawFrame()
		if !h.stopped {
			h.window.Call("requestAnimationFrame", h.raf)
		}
		return nil
	})
	h.rafReady = true
	h.window.Call("requestAnimationFrame", h.raf)
	// A Go wasm program must keep its main goroutine live for JS callbacks.
	// stop reports an application or renderer failure through this channel.
	return <-h.done
}

func (h *browserHost) drawFrame() {
	if h.stopped || h.runtime == nil || h.document.Get("hidden").Bool() {
		return
	}
	now := time.Now()
	h.frame++
	h.timing = engine.FrameTiming{Frame: h.frame, Elapsed: now.Sub(h.start), Delta: now.Sub(h.last)}
	h.last = now
	h.sampleGamepads()
	if err := h.runtime.Update(h.runtime.SampleInput(h.PollEvents())); err != nil {
		h.stop(err)
		return
	}
	if err := h.runtime.Draw(h.renderer); err != nil {
		h.stop(err)
	}
}

func (h *browserHost) stop(err error) {
	if h.stopped {
		return
	}
	h.stopped = true
	if err != nil {
		js.Global().Get("console").Call("error", "72 browser host stopped: "+err.Error())
	}
	if h.renderer != nil {
		h.renderer.Close()
		h.renderer = nil
	}
	for _, listener := range h.listeners {
		listener.target.Call("removeEventListener", listener.name, listener.callback)
		listener.callback.Release()
	}
	h.listeners = nil
	if !h.textInput.IsNull() && !h.textInput.IsUndefined() {
		h.textInput.Call("remove")
		h.textInput = js.Undefined()
	}
	if h.rafReady {
		h.raf.Release()
		h.rafReady = false
	}
	h.done <- err
}

func (h *browserHost) State() engine.WindowState { return h.state }

func (h *browserHost) InputCapabilities() engine.InputCapabilities { return h.inputCapabilities }

func (h *browserHost) SetTitle(value string) error {
	h.document.Set("title", value)
	h.state.Title = value
	return nil
}

func (h *browserHost) SetCursor(cursor engine.Cursor) error {
	var value string
	switch cursor {
	case engine.CursorDefault:
		value = "default"
	case engine.CursorPointer:
		value = "pointer"
	case engine.CursorText:
		value = "text"
	case engine.CursorCrosshair:
		value = "crosshair"
	case engine.CursorHidden:
		value = "none"
	default:
		return fmt.Errorf("set browser cursor: unsupported cursor %d", cursor)
	}
	h.canvas.Get("style").Set("cursor", value)
	return nil
}

func (*browserHost) ReadClipboard() (string, error) {
	return "", fmt.Errorf("read browser clipboard: asynchronous Clipboard API cannot satisfy synchronous host contract")
}

func (*browserHost) WriteClipboard(string) error {
	return fmt.Errorf("write browser clipboard: asynchronous Clipboard API cannot report completion through synchronous host contract")
}

// RequestClipboard starts one browser Clipboard API request. Browser
// permission and secure-context failures settle through PollClipboard so games
// can observe them without a browser-specific callback.
func (h *browserHost) RequestClipboard(request engine.ClipboardRequest) (engine.ClipboardRequestID, error) {
	if h.stopped {
		return 0, fmt.Errorf("request browser clipboard: host is stopped")
	}
	if request.Operation != engine.ClipboardRead && request.Operation != engine.ClipboardWrite {
		return 0, fmt.Errorf("request browser clipboard: unsupported operation %d", request.Operation)
	}
	if secure := h.window.Get("isSecureContext"); !secure.IsNull() && !secure.IsUndefined() && !secure.Bool() {
		return 0, fmt.Errorf("request browser clipboard: Clipboard API requires a secure context")
	}
	clipboard := h.window.Get("navigator").Get("clipboard")
	if clipboard.IsNull() || clipboard.IsUndefined() {
		return 0, fmt.Errorf("request browser clipboard: Clipboard API is unavailable")
	}
	method := "readText"
	if request.Operation == engine.ClipboardWrite {
		method = "writeText"
	}
	if function := clipboard.Get(method); function.IsNull() || function.IsUndefined() || function.Type() != js.TypeFunction {
		return 0, fmt.Errorf("request browser clipboard: Clipboard.%s is unavailable", method)
	}
	h.clipboardNext++
	entry := &browserClipboardRequest{id: h.clipboardNext, operation: request.Operation}
	entry.resolve = js.FuncOf(func(_ js.Value, values []js.Value) any {
		text := ""
		if entry.operation == engine.ClipboardRead && len(values) > 0 {
			text = values[0].String()
		}
		h.settleClipboard(entry, text, nil)
		return nil
	})
	entry.reject = js.FuncOf(func(_ js.Value, values []js.Value) any {
		h.settleClipboard(entry, "", browserClipboardRejection(values))
		return nil
	})
	h.clipboardRequests = append(h.clipboardRequests, entry)
	if request.Operation == engine.ClipboardRead {
		clipboard.Call(method).Call("then", entry.resolve, entry.reject)
	} else {
		clipboard.Call(method, request.Text).Call("then", entry.resolve, entry.reject)
	}
	return entry.id, nil
}

// PollClipboard returns completed browser clipboard operations in settlement
// order and clears them from this host.
func (h *browserHost) PollClipboard() []engine.ClipboardCompletion {
	completed := append([]engine.ClipboardCompletion(nil), h.clipboard...)
	h.clipboard = h.clipboard[:0]
	return completed
}

func (h *browserHost) settleClipboard(request *browserClipboardRequest, text string, err error) {
	if request == nil || request.settled {
		return
	}
	request.settled = true
	request.resolve.Release()
	request.reject.Release()
	for index, active := range h.clipboardRequests {
		if active != request {
			continue
		}
		h.clipboardRequests = append(h.clipboardRequests[:index], h.clipboardRequests[index+1:]...)
		break
	}
	if !h.stopped {
		h.clipboard = append(h.clipboard, engine.ClipboardCompletion{ID: request.id, Operation: request.operation, Text: text, Err: err})
	}
}

func browserClipboardRejection(values []js.Value) error {
	if len(values) == 0 || values[0].IsNull() || values[0].IsUndefined() {
		return fmt.Errorf("browser Clipboard API rejected the request")
	}
	value := values[0]
	if message := value.Get("message"); !message.IsNull() && !message.IsUndefined() && message.String() != "" {
		return fmt.Errorf("browser Clipboard API rejected the request: %s", message.String())
	}
	return fmt.Errorf("browser Clipboard API rejected the request: %s", value.String())
}

func (h *browserHost) Now() time.Time             { return time.Now() }
func (h *browserHost) Timing() engine.FrameTiming { return h.timing }

func (h *browserHost) PollEvents() []engine.Event {
	events := append([]engine.Event(nil), h.events...)
	h.events = h.events[:0]
	return events
}

func (h *browserHost) listen() {
	h.listenTo(h.document, "keydown", func(event js.Value) {
		if key, ok := browserKey(event.Get("code").String()); ok {
			event.Call("preventDefault")
			h.events = append(h.events, engine.Event{Kind: engine.EventKey, Key: key, Pressed: true})
		}
	})
	h.listenTo(h.document, "keyup", func(event js.Value) {
		if key, ok := browserKey(event.Get("code").String()); ok {
			event.Call("preventDefault")
			h.events = append(h.events, engine.Event{Kind: engine.EventKey, Key: key, Pressed: false})
		}
	})
	h.listenTo(h.canvas, "pointermove", func(event js.Value) {
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerMove, Position: h.pointerPosition(event)})
	})
	h.listenTo(h.canvas, "pointerdown", func(event js.Value) {
		h.textInput.Call("focus")
		if button, ok := browserButton(event.Get("button").Int()); ok {
			event.Call("preventDefault")
			h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: button, Pressed: true, Position: h.pointerPosition(event)})
		}
	})
	h.listenTo(h.textInput, "beforeinput", func(event js.Value) {
		inputType := event.Get("inputType").String()
		if event.Get("isComposing").Bool() || (inputType != "insertText" && inputType != "insertFromComposition") {
			return
		}
		if text := event.Get("data").String(); text != "" && utf8.ValidString(text) {
			h.events = append(h.events, engine.Event{Kind: engine.EventText, Text: text})
		}
	})
	h.listenTo(h.textInput, "input", func(js.Value) { h.textInput.Set("value", "") })
	h.listenTo(h.textInput, "compositionstart", func(event js.Value) {
		h.events = append(h.events, engine.Event{Kind: engine.EventComposition, Composition: engine.CompositionStart, Text: event.Get("data").String()})
	})
	h.listenTo(h.textInput, "compositionupdate", func(event js.Value) {
		h.events = append(h.events, engine.Event{Kind: engine.EventComposition, Composition: engine.CompositionUpdate, Text: event.Get("data").String()})
	})
	h.listenTo(h.textInput, "compositionend", func(event js.Value) {
		h.events = append(h.events, engine.Event{Kind: engine.EventComposition, Composition: engine.CompositionEnd, Text: event.Get("data").String()})
	})
	h.listenTo(h.canvas, "pointerup", func(event js.Value) {
		if button, ok := browserButton(event.Get("button").Int()); ok {
			h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: button, Pressed: false, Position: h.pointerPosition(event)})
		}
	})
	h.listenTo(h.canvas, "wheel", func(event js.Value) {
		event.Call("preventDefault")
		scaleX, scaleY := h.cssScales()
		h.events = append(h.events, engine.Event{Kind: engine.EventPointerWheel, Scroll: engine.Vec2{X: event.Get("deltaX").Float() / scaleX, Y: -event.Get("deltaY").Float() / scaleY}})
	})
	h.listenTo(h.window, "resize", func(js.Value) { h.resizeCanvas() })
	h.listenTo(h.window, "focus", func(js.Value) { h.setFocus(!h.document.Get("hidden").Bool() && documentHasFocus(h.document)) })
	h.listenTo(h.window, "blur", func(js.Value) { h.setFocus(false) })
	h.listenTo(h.document, "visibilitychange", func(js.Value) {
		visible := !h.document.Get("hidden").Bool()
		h.state.Visible = visible
		if !visible {
			h.setFocus(false)
			return
		}
		// Do not feed a hidden-tab interval into the next simulation update.
		h.last = time.Now()
		h.setFocus(documentHasFocus(h.document))
	})
}

func (h *browserHost) listenTo(target js.Value, name string, fn func(js.Value)) {
	callback := js.FuncOf(func(_ js.Value, args []js.Value) any { fn(args[0]); return nil })
	h.listeners = append(h.listeners, browserListener{target: target, name: name, callback: callback})
	target.Call("addEventListener", name, callback)
}

func (h *browserHost) resizeCanvas() {
	cssWidth := int(math.Round(h.canvas.Call("getBoundingClientRect").Get("width").Float()))
	cssHeight := int(math.Round(h.canvas.Call("getBoundingClientRect").Get("height").Float()))
	if cssWidth <= 0 || cssHeight <= 0 {
		return
	}
	width, height := scaledCanvasSize(cssWidth, cssHeight, devicePixelRatio(h.window))
	if width == int(h.state.DrawableSize.W) && height == int(h.state.DrawableSize.H) {
		return
	}
	h.canvas.Set("width", width)
	h.canvas.Set("height", height)
	if err := h.renderer.Resize(width, height); err != nil {
		h.stop(err)
		return
	}
	h.state.DrawableSize = engine.Size{W: float64(width), H: float64(height)}
	h.state.Scale = float64(width) / h.config.Viewport.W
	h.events = append(h.events, engine.Event{Kind: engine.EventWindowResized, Window: h.state})
}

func (h *browserHost) setFocus(value bool) {
	if h.state.Focused == value {
		return
	}
	h.state.Focused = value
	h.events = append(h.events, engine.Event{Kind: engine.EventFocusChanged, Focused: value})
}

func (h *browserHost) pointerPosition(event js.Value) engine.Vec2 {
	scaleX, scaleY := h.cssScales()
	bounds := h.canvas.Call("getBoundingClientRect")
	return engine.Vec2{X: (event.Get("clientX").Float() - bounds.Get("left").Float()) / scaleX, Y: (event.Get("clientY").Float() - bounds.Get("top").Float()) / scaleY}
}

func (h *browserHost) cssScales() (float64, float64) {
	bounds := h.canvas.Call("getBoundingClientRect")
	width, height := bounds.Get("width").Float(), bounds.Get("height").Float()
	if width <= 0 || height <= 0 {
		scale := float64(h.config.WindowScale)
		return scale, scale
	}
	return width / h.config.Viewport.W, height / h.config.Viewport.H
}

func devicePixelRatio(window js.Value) float64 {
	value := window.Get("devicePixelRatio")
	if value.IsNull() || value.IsUndefined() || value.Float() <= 0 {
		return 1
	}
	return value.Float()
}

func documentHasFocus(document js.Value) bool {
	method := document.Get("hasFocus")
	return !method.IsNull() && !method.IsUndefined() && document.Call("hasFocus").Bool()
}

func scaledCanvasSize(width, height int, scale float64) (int, int) {
	return max(1, int(math.Round(float64(width)*scale))), max(1, int(math.Round(float64(height)*scale)))
}

func browserButton(value int) (engine.PointerButton, bool) {
	switch value {
	case 0:
		return engine.PointerPrimary, true
	case 1:
		return engine.PointerMiddle, true
	case 2:
		return engine.PointerSecondary, true
	default:
		return 0, false
	}
}

func browserKey(value string) (engine.Key, bool) { key, ok := browserKeys[value]; return key, ok }

var browserKeys = map[string]engine.Key{
	"KeyA": engine.KeyA, "KeyB": engine.KeyB, "KeyC": engine.KeyC, "KeyD": engine.KeyD, "KeyE": engine.KeyE, "KeyF": engine.KeyF, "KeyG": engine.KeyG, "KeyH": engine.KeyH, "KeyI": engine.KeyI, "KeyJ": engine.KeyJ, "KeyK": engine.KeyK, "KeyL": engine.KeyL, "KeyM": engine.KeyM, "KeyN": engine.KeyN, "KeyO": engine.KeyO, "KeyP": engine.KeyP, "KeyQ": engine.KeyQ, "KeyR": engine.KeyR, "KeyS": engine.KeyS, "KeyT": engine.KeyT, "KeyU": engine.KeyU, "KeyV": engine.KeyV, "KeyW": engine.KeyW, "KeyX": engine.KeyX, "KeyY": engine.KeyY, "KeyZ": engine.KeyZ,
	"Digit0": engine.KeyDigit0, "Digit1": engine.KeyDigit1, "Digit2": engine.KeyDigit2, "Digit3": engine.KeyDigit3, "Digit4": engine.KeyDigit4, "Digit5": engine.KeyDigit5, "Digit6": engine.KeyDigit6, "Digit7": engine.KeyDigit7, "Digit8": engine.KeyDigit8, "Digit9": engine.KeyDigit9,
	"Backquote": engine.KeyBackquote, "Backslash": engine.KeyBackslash, "BracketLeft": engine.KeyBracketLeft, "BracketRight": engine.KeyBracketRight, "Comma": engine.KeyComma, "Equal": engine.KeyEqual, "IntlBackslash": engine.KeyIntlBackslash, "Minus": engine.KeyMinus, "Period": engine.KeyPeriod, "Quote": engine.KeyQuote, "Semicolon": engine.KeySemicolon, "Slash": engine.KeySlash,
	"AltLeft": engine.KeyAltLeft, "AltRight": engine.KeyAltRight, "Backspace": engine.KeyBackspace, "CapsLock": engine.KeyCapsLock, "ContextMenu": engine.KeyContextMenu, "ControlLeft": engine.KeyControlLeft, "ControlRight": engine.KeyControlRight, "Enter": engine.KeyEnter, "MetaLeft": engine.KeyMetaLeft, "MetaRight": engine.KeyMetaRight, "ShiftLeft": engine.KeyShiftLeft, "ShiftRight": engine.KeyShiftRight, "Space": engine.KeySpace, "Tab": engine.KeyTab,
	"Delete": engine.KeyDelete, "End": engine.KeyEnd, "Help": engine.KeyHelp, "Home": engine.KeyHome, "Insert": engine.KeyInsert, "PageDown": engine.KeyPageDown, "PageUp": engine.KeyPageUp, "ArrowDown": engine.KeyArrowDown, "ArrowLeft": engine.KeyArrowLeft, "ArrowRight": engine.KeyArrowRight, "ArrowUp": engine.KeyArrowUp,
	"NumLock": engine.KeyNumLock, "Numpad0": engine.KeyNumpad0, "Numpad1": engine.KeyNumpad1, "Numpad2": engine.KeyNumpad2, "Numpad3": engine.KeyNumpad3, "Numpad4": engine.KeyNumpad4, "Numpad5": engine.KeyNumpad5, "Numpad6": engine.KeyNumpad6, "Numpad7": engine.KeyNumpad7, "Numpad8": engine.KeyNumpad8, "Numpad9": engine.KeyNumpad9, "NumpadAdd": engine.KeyNumpadAdd, "NumpadDecimal": engine.KeyNumpadDecimal, "NumpadDivide": engine.KeyNumpadDivide, "NumpadEnter": engine.KeyNumpadEnter, "NumpadEqual": engine.KeyNumpadEqual, "NumpadMultiply": engine.KeyNumpadMultiply, "NumpadSubtract": engine.KeyNumpadSubtract,
	"Escape": engine.KeyEscape, "F1": engine.KeyF1, "F2": engine.KeyF2, "F3": engine.KeyF3, "F4": engine.KeyF4, "F5": engine.KeyF5, "F6": engine.KeyF6, "F7": engine.KeyF7, "F8": engine.KeyF8, "F9": engine.KeyF9, "F10": engine.KeyF10, "F11": engine.KeyF11, "F12": engine.KeyF12, "Pause": engine.KeyPause, "PrintScreen": engine.KeyPrintScreen, "ScrollLock": engine.KeyScrollLock,
}

type browserGamepad struct {
	mapping   engine.GamepadMapping
	supported bool
	buttons   []float64
	axes      []float64
}

func browserCapabilities(window js.Value) engine.InputCapabilities {
	capabilities := engine.InputCapabilities{Keyboard: engine.InputAvailable, Composition: engine.InputAvailable}
	gamepads := window.Get("navigator").Get("getGamepads")
	if !gamepads.IsNull() && !gamepads.IsUndefined() && gamepads.Type() == js.TypeFunction {
		capabilities.Gamepad = engine.InputAvailable
	}
	return capabilities
}

func (h *browserHost) sampleGamepads() {
	if h.inputCapabilities.Gamepad != engine.InputAvailable {
		return
	}
	values := h.window.Get("navigator").Call("getGamepads")
	seen := make(map[uint32]struct{}, values.Length())
	for index := 0; index < values.Length(); index++ {
		gamepad := values.Index(index)
		if gamepad.IsNull() || gamepad.IsUndefined() || !gamepad.Get("connected").Bool() {
			continue
		}
		id := uint32(index)
		seen[id] = struct{}{}
		mapping := engine.GamepadMappingUnknown
		if gamepad.Get("mapping").String() == "standard" {
			mapping = engine.GamepadMappingStandard
		}
		current := browserGamepad{mapping: mapping, supported: mapping == engine.GamepadMappingStandard}
		if current.supported {
			current.buttons = browserGamepadButtons(gamepad.Get("buttons"))
			current.axes = browserGamepadAxes(gamepad.Get("axes"))
		}
		previous, exists := h.gamepads[id]
		if !exists || previous.mapping != current.mapping {
			h.events = append(h.events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: id, Connected: true, GamepadMapping: mapping, GamepadUnsupported: !current.supported})
		}
		if current.supported {
			h.appendGamepadChanges(id, previous, current)
		}
		h.gamepads[id] = current
	}
	for id, previous := range h.gamepads {
		if _, ok := seen[id]; !ok {
			h.events = append(h.events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: id, Connected: false, GamepadMapping: previous.mapping, GamepadUnsupported: !previous.supported})
			delete(h.gamepads, id)
		}
	}
}

func browserGamepadButtons(values js.Value) []float64 {
	buttons := make([]float64, 17)
	for index := range buttons {
		if index >= values.Length() {
			break
		}
		buttons[index] = math.Max(0, math.Min(1, values.Index(index).Get("value").Float()))
	}
	return buttons
}

func browserGamepadAxes(values js.Value) []float64 {
	axes := make([]float64, 4)
	for index := range axes {
		if index >= values.Length() {
			break
		}
		axes[index] = math.Max(-1, math.Min(1, values.Index(index).Float()))
	}
	return axes
}

func (h *browserHost) appendGamepadChanges(id uint32, previous, current browserGamepad) {
	for index, value := range current.buttons {
		if !previous.supported || index >= len(previous.buttons) || math.Abs(value-previous.buttons[index]) > .001 {
			h.events = append(h.events, engine.Event{Kind: engine.EventGamepadButton, DeviceID: id, Button: engine.GamepadButton(index), Value: value, Pressed: value >= .5})
		}
	}
	for index, value := range current.axes {
		if !previous.supported || index >= len(previous.axes) || math.Abs(value-previous.axes[index]) > .001 {
			h.events = append(h.events, engine.Event{Kind: engine.EventGamepadAxis, DeviceID: id, Axis: engine.GamepadAxis(index), Value: value})
		}
	}
}
