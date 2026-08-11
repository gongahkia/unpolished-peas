package main

import (
	"testing"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render"
	"github.com/gongahkia/72/example/wukong/internal/sim"
)

func TestFollowCameraClampsToWorldBounds(t *testing.T) {
	if camera := followCamera(sim.Vec{X: 10, Y: 10}); camera != (sim.Vec{}) {
		t.Fatalf("camera escaped upper-left bound: %+v", camera)
	}
	if camera := followCamera(sim.Vec{X: sim.ArenaW - 5, Y: sim.ArenaH - 5}); camera != (sim.Vec{X: sim.ArenaW - float64(logicalW), Y: sim.ArenaH - float64(logicalH)}) {
		t.Fatalf("camera escaped lower-right bound: %+v", camera)
	}
	if camera := followCamera(sim.Vec{X: 900, Y: 500}); camera != (sim.Vec{X: 580, Y: 320}) {
		t.Fatalf("camera did not center inside the world: %+v", camera)
	}
}

func TestAimLabelUsesCompassDirections(t *testing.T) {
	for _, test := range []struct {
		aim  sim.Vec
		want string
	}{
		{sim.Vec{X: 1}, "E"},
		{sim.Vec{Y: -1}, "N"},
		{sim.Vec{X: -1, Y: 1}, "SW"},
		{sim.Vec{}, "E"},
	} {
		if got := aimLabel(test.aim); got != test.want {
			t.Fatalf("aimLabel(%+v) = %q, want %q", test.aim, got, test.want)
		}
	}
}

func TestWukongActionMapPreservesTheDownAxisBinding(t *testing.T) {
	binding := actionMap()[actionDown]
	if binding.Axis == nil {
		t.Fatal("down action is not axis-bound")
	}
	if got, want := binding.Axis.GamepadAxis, engine.GamepadAxis(1); got != want {
		t.Fatalf("down gamepad axis = %d, want %d", got, want)
	}
	if len(binding.Axis.Positive) != 1 || binding.Axis.Positive[0] != engine.KeyS {
		t.Fatalf("down keyboard binding = %+v, want [S]", binding.Axis.Positive)
	}
}

func TestWukongActiveLayersSubmitCommandFrames(t *testing.T) {
	runtime, err := engine.NewRuntime(engine.Config{
		Title:       "test",
		Viewport:    engine.Size{W: logicalW, H: logicalH},
		WindowScale: 1,
		Actions:     actionMap(),
	}, &wukongGame{})
	if err != nil {
		t.Fatal(err)
	}
	canvas := &wukongCommandCanvas{}
	if err := runtime.Draw(canvas); err != nil {
		t.Fatal(err)
	}
	if canvas.immediateCalls != 0 || canvas.commandFrames == 0 {
		t.Fatalf("immediate=%d command frames=%d", canvas.immediateCalls, canvas.commandFrames)
	}
}

type wukongCommandCanvas struct {
	immediateCalls int
	commandFrames  int
}

func (c *wukongCommandCanvas) Clear(engine.Color)                            { c.immediateCalls++ }
func (c *wukongCommandCanvas) FillRect(engine.Rect, engine.Color)            { c.immediateCalls++ }
func (c *wukongCommandCanvas) StrokeRect(engine.Rect, float64, engine.Color) { c.immediateCalls++ }
func (c *wukongCommandCanvas) FillCircle(engine.Vec2, float64, engine.Color) { c.immediateCalls++ }
func (c *wukongCommandCanvas) StrokeCircle(engine.Vec2, float64, float64, engine.Color) {
	c.immediateCalls++
}
func (c *wukongCommandCanvas) StrokeLine(engine.Vec2, engine.Vec2, float64, engine.Color) {
	c.immediateCalls++
}
func (c *wukongCommandCanvas) DrawText(engine.Vec2, string, engine.Color) { c.immediateCalls++ }
func (c *wukongCommandCanvas) RenderCommands(render.Frame) error {
	c.commandFrames++
	return nil
}
