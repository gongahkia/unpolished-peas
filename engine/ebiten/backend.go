// Package ebiten is the temporary Ebitengine compatibility adapter for the
// engine runtime. It is not the permanent 72 renderer implementation.
package ebiten

import (
	"image/color"
	"math"

	"github.com/gongahkia/72/engine"
	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/inpututil"
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
	return ebiten.RunGame(game{runtime: runtime})
}

type game struct{ runtime *engine.Runtime }

func (g game) Update() error { return g.runtime.Update(sampleInput(g.runtime.Actions())) }

func (g game) Draw(screen *ebiten.Image) { g.runtime.Draw(canvas{image: screen}) }

func (g game) Layout(_, _ int) (int, int) {
	viewport := g.runtime.Config().Viewport
	return int(viewport.W), int(viewport.H)
}

func sampleInput(actions engine.ActionMap) engine.Input {
	states := make(map[engine.Action]engine.ActionState, len(actions))
	gamepads := ebiten.AppendGamepadIDs(nil)
	for _, action := range actions.Actions() {
		binding := actions[action]
		state := engine.ActionState{}
		for _, key := range binding.Keys {
			state.Down = state.Down || keyPressed(key)
			state.Pressed = state.Pressed || keyJustPressed(key)
			state.Released = state.Released || keyJustReleased(key)
		}
		if len(gamepads) > 0 {
			for _, button := range binding.GamepadButtons {
				state.Down = state.Down || ebiten.IsGamepadButtonPressed(gamepads[0], ebiten.GamepadButton(button))
				state.Pressed = state.Pressed || inpututil.IsGamepadButtonJustPressed(gamepads[0], ebiten.GamepadButton(button))
				state.Released = state.Released || inpututil.IsGamepadButtonJustReleased(gamepads[0], ebiten.GamepadButton(button))
			}
		}
		if binding.Axis != nil {
			value, down, pressed, released := sampleAxis(*binding.Axis, gamepads)
			state.Value = value
			state.Down = state.Down || down
			state.Pressed = state.Pressed || pressed
			state.Released = state.Released || released
		}
		states[action] = state
	}
	return engine.NewInput(states)
}

func sampleAxis(binding engine.AxisBinding, gamepads []ebiten.GamepadID) (float64, bool, bool, bool) {
	negative, positive := false, false
	pressed, released := false, false
	for _, key := range binding.Negative {
		negative = negative || keyPressed(key)
		pressed = pressed || keyJustPressed(key)
		released = released || keyJustReleased(key)
	}
	for _, key := range binding.Positive {
		positive = positive || keyPressed(key)
		pressed = pressed || keyJustPressed(key)
		released = released || keyJustReleased(key)
	}
	if negative != positive {
		if negative {
			return -1, true, pressed, released
		}
		return 1, true, pressed, released
	}
	if binding.UseGamepad && len(gamepads) > 0 {
		value := ebiten.GamepadAxisValue(gamepads[0], int(binding.GamepadAxis))
		if math.Abs(value) >= binding.Deadzone {
			return value, true, pressed, released
		}
	}
	return 0, false, pressed, released
}

func keyPressed(key engine.Key) bool {
	ebitenKey, ok := ebitenKeyFor(key)
	return ok && ebiten.IsKeyPressed(ebitenKey)
}

func keyJustPressed(key engine.Key) bool {
	ebitenKey, ok := ebitenKeyFor(key)
	return ok && inpututil.IsKeyJustPressed(ebitenKey)
}

func keyJustReleased(key engine.Key) bool {
	ebitenKey, ok := ebitenKeyFor(key)
	return ok && inpututil.IsKeyJustReleased(ebitenKey)
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

type canvas struct{ image *ebiten.Image }

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
