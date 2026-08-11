// Package ebiten is the temporary Ebitengine compatibility adapter for the
// engine runtime. It is not the permanent 72 renderer implementation.
package ebiten

import (
	"image/color"
	"sort"

	"github.com/gongahkia/72/engine"
	engineRender "github.com/gongahkia/72/engine/render"
	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/text"
	"github.com/hajimehoshi/ebiten/v2/vector"
	"golang.org/x/image/font/basicfont"
)

// Backend hosts an engine runtime with Ebitengine.
type Backend struct{}

// Run starts an Ebitengine application through the engine lifecycle.
func Run(config engine.Config, app engine.Application) error {
	return engine.Run(config, app, Backend{})
}

// Run implements engine.Backend.
func (Backend) Run(runtime *engine.Runtime) error {
	config := runtime.Config()
	ebiten.SetWindowSize(int(config.Viewport.W)*config.WindowScale, int(config.Viewport.H)*config.WindowScale)
	if config.Title != "" {
		ebiten.SetWindowTitle(config.Title)
	}
	return ebiten.RunGame(&game{runtime: runtime, renderer: NewRenderBackend(nil), gamepads: make(map[ebiten.GamepadID]struct{})})
}

type game struct {
	runtime  *engine.Runtime
	renderer *RenderBackend
	drawErr  error
	gamepads map[ebiten.GamepadID]struct{}
	focused  bool
}

func (g *game) Update() error {
	if g.drawErr != nil {
		return g.drawErr
	}
	return g.runtime.Update(g.runtime.SampleInput(g.events()))
}

func (g *game) Draw(screen *ebiten.Image) {
	g.renderer.SetTarget(screen)
	g.drawErr = g.runtime.Draw(canvas{image: screen, renderer: g.renderer})
}

func (g *game) Layout(_, _ int) (int, int) {
	viewport := g.runtime.Config().Viewport
	return int(viewport.W), int(viewport.H)
}

func (g *game) events() []engine.Event {
	events := make([]engine.Event, 0)
	focused := ebiten.IsFocused()
	if focused != g.focused {
		events = append(events, engine.Event{Kind: engine.EventFocusChanged, Focused: focused})
		g.focused = focused
	}
	if !focused {
		g.gamepads = make(map[ebiten.GamepadID]struct{})
		return events
	}
	for _, key := range configuredKeys(g.runtime.Actions()) {
		events = append(events, engine.Event{Kind: engine.EventKey, Key: key, Pressed: keyPressed(key)})
	}
	x, y := ebiten.CursorPosition()
	events = append(events, engine.Event{Kind: engine.EventPointerMove, Position: engine.Vec2{X: float64(x), Y: float64(y)}})
	for _, button := range []struct {
		ebiten   ebiten.MouseButton
		portable engine.PointerButton
	}{{ebiten.MouseButtonLeft, engine.PointerPrimary}, {ebiten.MouseButtonRight, engine.PointerSecondary}, {ebiten.MouseButtonMiddle, engine.PointerMiddle}} {
		events = append(events, engine.Event{Kind: engine.EventPointerButton, PointerButton: button.portable, Pressed: ebiten.IsMouseButtonPressed(button.ebiten)})
	}
	if scrollX, scrollY := ebiten.Wheel(); scrollX != 0 || scrollY != 0 {
		events = append(events, engine.Event{Kind: engine.EventPointerWheel, Scroll: engine.Vec2{X: scrollX, Y: scrollY}})
	}
	if characters := ebiten.AppendInputChars(nil); len(characters) > 0 {
		events = append(events, engine.Event{Kind: engine.EventText, Text: string(characters)})
	}
	ids := ebiten.AppendGamepadIDs(nil)
	sort.Slice(ids, func(left, right int) bool { return ids[left] < ids[right] })
	current := make(map[ebiten.GamepadID]struct{}, len(ids))
	for _, id := range ids {
		current[id] = struct{}{}
		if _, known := g.gamepads[id]; !known {
			events = append(events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: uint32(id), Connected: true})
		}
		for button := range ebiten.GamepadButtonCount(id) {
			events = append(events, engine.Event{Kind: engine.EventGamepadButton, DeviceID: uint32(id), Button: engine.GamepadButton(button), Pressed: ebiten.IsGamepadButtonPressed(id, ebiten.GamepadButton(button))})
		}
		for axis := range ebiten.GamepadAxisCount(id) {
			events = append(events, engine.Event{Kind: engine.EventGamepadAxis, DeviceID: uint32(id), Axis: engine.GamepadAxis(axis), Value: ebiten.GamepadAxisValue(id, axis)})
		}
	}
	for id := range g.gamepads {
		if _, connected := current[id]; !connected {
			events = append(events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: uint32(id), Connected: false})
		}
	}
	g.gamepads = current
	return events
}

func configuredKeys(actions engine.ActionMap) []engine.Key {
	keys := make(map[engine.Key]struct{})
	for _, action := range actions.Actions() {
		binding := actions[action]
		for _, key := range binding.Keys {
			keys[key] = struct{}{}
		}
		if binding.Axis != nil {
			for _, key := range binding.Axis.Negative {
				keys[key] = struct{}{}
			}
			for _, key := range binding.Axis.Positive {
				keys[key] = struct{}{}
			}
		}
	}
	values := make([]engine.Key, 0, len(keys))
	for key := range keys {
		values = append(values, key)
	}
	sort.Slice(values, func(left, right int) bool { return values[left] < values[right] })
	return values
}

func keyPressed(key engine.Key) bool {
	ebitenKey, ok := ebitenKeyFor(key)
	return ok && ebiten.IsKeyPressed(ebitenKey)
}

func ebitenKeyFor(key engine.Key) (ebiten.Key, bool) {
	switch key {
	case engine.KeyA:
		return ebiten.KeyA, true
	case engine.KeyD:
		return ebiten.KeyD, true
	case engine.KeyE:
		return ebiten.KeyE, true
	case engine.KeyJ:
		return ebiten.KeyJ, true
	case engine.KeyP:
		return ebiten.KeyP, true
	case engine.KeyS:
		return ebiten.KeyS, true
	case engine.KeyW:
		return ebiten.KeyW, true
	case engine.KeySpace:
		return ebiten.KeySpace, true
	case engine.KeyShift:
		return ebiten.KeyShift, true
	case engine.KeyEnter:
		return ebiten.KeyEnter, true
	case engine.KeyPeriod:
		return ebiten.KeyPeriod, true
	case engine.KeyTab:
		return ebiten.KeyTab, true
	case engine.KeyArrowDown:
		return ebiten.KeyArrowDown, true
	case engine.KeyArrowLeft:
		return ebiten.KeyArrowLeft, true
	case engine.KeyArrowRight:
		return ebiten.KeyArrowRight, true
	case engine.KeyArrowUp:
		return ebiten.KeyArrowUp, true
	case engine.KeyF1:
		return ebiten.KeyF1, true
	case engine.KeyF2:
		return ebiten.KeyF2, true
	case engine.KeyF6:
		return ebiten.KeyF6, true
	default:
		return 0, false
	}
}

type canvas struct {
	image    *ebiten.Image
	renderer *RenderBackend
}

func (c canvas) RenderCommands(frame engineRender.Frame) error { return c.renderer.Render(frame) }

func (c canvas) Clear(value engine.Color) { c.image.Fill(ebitenColor(value)) }

func (c canvas) FillRect(rect engine.Rect, value engine.Color) {
	vector.DrawFilledRect(c.image, float32(rect.X), float32(rect.Y), float32(rect.W), float32(rect.H), ebitenColor(value), false)
}

func (c canvas) StrokeRect(rect engine.Rect, width float64, value engine.Color) {
	vector.StrokeRect(c.image, float32(rect.X), float32(rect.Y), float32(rect.W), float32(rect.H), float32(width), ebitenColor(value), false)
}

func (c canvas) FillCircle(center engine.Vec2, radius float64, value engine.Color) {
	vector.DrawFilledCircle(c.image, float32(center.X), float32(center.Y), float32(radius), ebitenColor(value), true)
}

func (c canvas) StrokeCircle(center engine.Vec2, radius, width float64, value engine.Color) {
	vector.StrokeCircle(c.image, float32(center.X), float32(center.Y), float32(radius), float32(width), ebitenColor(value), true)
}

func (c canvas) StrokeLine(start, end engine.Vec2, width float64, value engine.Color) {
	vector.StrokeLine(c.image, float32(start.X), float32(start.Y), float32(end.X), float32(end.Y), float32(width), ebitenColor(value), true)
}

func (c canvas) DrawText(position engine.Vec2, value string, tint engine.Color) {
	text.Draw(c.image, value, basicfont.Face7x13, int(position.X), int(position.Y), ebitenColor(tint))
}

func ebitenColor(value engine.Color) color.RGBA {
	return color.RGBA{R: value.R, G: value.G, B: value.B, A: value.A}
}
