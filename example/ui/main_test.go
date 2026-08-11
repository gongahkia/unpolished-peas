package main

import (
	"os"
	"strings"
	"testing"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render"
)

func TestSampleSupportsKeyboardPointerAndCommandRendering(t *testing.T) {
	sample := &sampleUI{}
	runtime, err := engine.NewRuntime(sampleConfig(), sample)
	if err != nil {
		t.Fatalf("new runtime: %v", err)
	}
	if err := runtime.Update(engine.NewInput(map[engine.Action]engine.ActionState{actionFocusNext: {Down: true, Pressed: true}})); err != nil {
		t.Fatalf("keyboard focus update: %v", err)
	}
	if focus, ok := sample.tree.Focus(); !ok || focus != sample.start {
		t.Fatalf("keyboard focus = %d, %t", focus, ok)
	}
	if err := runtime.Update(engine.NewInput(map[engine.Action]engine.ActionState{actionActivate: {Down: true, Pressed: true}})); err != nil {
		t.Fatalf("keyboard activation update: %v", err)
	}
	if sample.message != "start selected" {
		t.Fatalf("keyboard activation message = %q", sample.message)
	}
	if err := runtime.Update(runtime.SampleInput([]engine.Event{{Kind: engine.EventPointerMove, Position: engine.Vec2{X: 20, Y: 58}}, {Kind: engine.EventPointerButton, PointerButton: engine.PointerPrimary, Pressed: true}})); err != nil {
		t.Fatalf("pointer press update: %v", err)
	}
	if err := runtime.Update(runtime.SampleInput([]engine.Event{{Kind: engine.EventPointerMove, Position: engine.Vec2{X: 20, Y: 58}}, {Kind: engine.EventPointerButton, PointerButton: engine.PointerPrimary, Pressed: false}})); err != nil {
		t.Fatalf("pointer release update: %v", err)
	}
	if sample.message != "preferences selected" {
		t.Fatalf("pointer activation message = %q", sample.message)
	}
	canvas := &recordingCanvas{}
	if err := runtime.Draw(canvas); err != nil {
		t.Fatalf("draw: %v", err)
	}
	if len(canvas.frames) != 1 {
		t.Fatalf("command frames = %d, want 1", len(canvas.frames))
	}
	commands := canvas.frames[0].Queue.Commands()
	if len(commands) < 8 || commands[0].Kind != render.Clear {
		t.Fatalf("UI commands = %+v", commands)
	}
}

func TestWasmLauncherTargetsUISample(t *testing.T) {
	page, err := os.ReadFile("web/index.html")
	if err != nil {
		t.Fatalf("read wasm launcher: %v", err)
	}
	if !strings.Contains(string(page), `fetch("ui-sample.wasm")`) || strings.Contains(string(page), "first-game.wasm") {
		t.Fatalf("wasm launcher targets the wrong binary:\n%s", page)
	}
}

type recordingCanvas struct{ frames []render.Frame }

func (c *recordingCanvas) Clear(engine.Color)                                         {}
func (c *recordingCanvas) FillRect(engine.Rect, engine.Color)                         {}
func (c *recordingCanvas) StrokeRect(engine.Rect, float64, engine.Color)              {}
func (c *recordingCanvas) FillCircle(engine.Vec2, float64, engine.Color)              {}
func (c *recordingCanvas) StrokeCircle(engine.Vec2, float64, float64, engine.Color)   {}
func (c *recordingCanvas) StrokeLine(engine.Vec2, engine.Vec2, float64, engine.Color) {}
func (c *recordingCanvas) DrawText(engine.Vec2, string, engine.Color)                 {}
func (c *recordingCanvas) RenderCommands(frame render.Frame) error {
	c.frames = append(c.frames, frame)
	return nil
}
