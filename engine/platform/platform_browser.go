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
	config   engine.Config
	document js.Value
	window   js.Value
	canvas   js.Value
	renderer *webgpu.Renderer

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
		config: config, document: document, window: window, canvas: canvas, renderer: renderer, start: now, last: now,
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
	if h.rafReady {
		h.raf.Release()
		h.rafReady = false
	}
	h.done <- err
}

func (h *browserHost) State() engine.WindowState { return h.state }

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

func (h *browserHost) WriteClipboard(value string) error {
	clipboard := h.window.Get("navigator").Get("clipboard")
	if clipboard.IsNull() || clipboard.IsUndefined() {
		return fmt.Errorf("write browser clipboard: Clipboard API is unavailable")
	}
	clipboard.Call("writeText", value)
	return nil
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
		if text := browserText(event); text != "" {
			h.events = append(h.events, engine.Event{Kind: engine.EventText, Text: text})
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
		h.canvas.Call("focus")
		if button, ok := browserButton(event.Get("button").Int()); ok {
			event.Call("preventDefault")
			h.events = append(h.events, engine.Event{Kind: engine.EventPointerButton, PointerButton: button, Pressed: true, Position: h.pointerPosition(event)})
		}
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

func browserKey(value string) (engine.Key, bool) {
	switch value {
	case "KeyA":
		return engine.KeyA, true
	case "KeyD":
		return engine.KeyD, true
	case "KeyE":
		return engine.KeyE, true
	case "KeyJ":
		return engine.KeyJ, true
	case "KeyP":
		return engine.KeyP, true
	case "KeyS":
		return engine.KeyS, true
	case "KeyW":
		return engine.KeyW, true
	case "Space":
		return engine.KeySpace, true
	case "ShiftLeft", "ShiftRight":
		return engine.KeyShift, true
	case "Enter":
		return engine.KeyEnter, true
	case "Period":
		return engine.KeyPeriod, true
	case "Tab":
		return engine.KeyTab, true
	case "ArrowDown":
		return engine.KeyArrowDown, true
	case "ArrowLeft":
		return engine.KeyArrowLeft, true
	case "ArrowRight":
		return engine.KeyArrowRight, true
	case "ArrowUp":
		return engine.KeyArrowUp, true
	case "F1":
		return engine.KeyF1, true
	case "F2":
		return engine.KeyF2, true
	case "F6":
		return engine.KeyF6, true
	default:
		return "", false
	}
}

func browserText(event js.Value) string {
	if event.Get("ctrlKey").Bool() || event.Get("altKey").Bool() || event.Get("metaKey").Bool() {
		return ""
	}
	value := event.Get("key").String()
	if utf8.RuneCountInString(value) != 1 {
		return ""
	}
	return value
}
