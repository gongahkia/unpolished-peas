package engine

import "testing"

func TestLayerStackOrdersAndTransformsArbitraryLayers(t *testing.T) {
	stack := &LayerStack{}
	order := make([]string, 0, 130)
	for index := 0; index < 128; index++ {
		id := string(rune('a'+index%26)) + string(rune('A'+index/26))
		if err := stack.Add(Layer{ID: id, Order: 10, Space: ScreenSpace, Draw: func(Frame) { order = append(order, id) }}); err != nil {
			t.Fatalf("add layer %d: %v", index, err)
		}
	}
	if err := stack.Add(Layer{ID: "deep", Order: -10, Space: WorldSpace, Parallax: .25, Draw: func(frame Frame) {
		frame.Canvas.FillRect(Rect{X: 384, Y: 100, W: 1, H: 1}, Color{})
	}}); err != nil {
		t.Fatalf("add deep layer: %v", err)
	}
	canvas := &recordingCanvas{}
	camera := NewCamera(Size{W: 640, H: 360})
	camera.SetPosition(Vec2{X: 160})
	stack.draw(canvas, camera, 1)
	if len(canvas.rects) != 1 || canvas.rects[0].X != 344 {
		t.Fatalf("deep layer rect = %+v, want X=344", canvas.rects)
	}
	if len(order) != 128 {
		t.Fatalf("ordered layer callbacks = %d, want 128", len(order))
	}
	if order[0] != "aA" || order[len(order)-1] != "xE" {
		t.Fatalf("equal-order layers lost registration order: first=%q last=%q", order[0], order[len(order)-1])
	}
}

func TestLayerStackRejectsDuplicatesAndSupportsMutation(t *testing.T) {
	stack := &LayerStack{}
	layer := Layer{ID: "world", Space: WorldSpace, Parallax: 1, Draw: func(Frame) {}}
	if err := stack.Add(layer); err != nil {
		t.Fatalf("add layer: %v", err)
	}
	if err := stack.Add(layer); err == nil {
		t.Fatal("duplicate layer registration succeeded")
	}
	if err := stack.SetOrder("world", 5); err != nil {
		t.Fatalf("set order: %v", err)
	}
	if got := stack.Layers()[0].Order; got != 5 {
		t.Fatalf("layer order = %d, want 5", got)
	}
	if !stack.Remove("world") || stack.Remove("world") {
		t.Fatal("remove did not report layer presence correctly")
	}
}

func TestActionMapAndInputExposeStableActionState(t *testing.T) {
	actions := ActionMap{Action("move"): {Axis: &AxisBinding{Negative: []Key{KeyA}, Positive: []Key{KeyD}, UseGamepad: true, Deadzone: .2}}}
	if err := actions.Validate(); err != nil {
		t.Fatalf("validate actions: %v", err)
	}
	input := NewInput(map[Action]ActionState{Action("move"): {Down: true, Value: -1}})
	if !input.Down("move") || input.Axis("move") != -1 || input.Pressed("move") {
		t.Fatalf("action state = %+v", input.State("move"))
	}
}

type recordingCanvas struct{ rects []Rect }

func (c *recordingCanvas) Clear(Color)                                {}
func (c *recordingCanvas) FillRect(rect Rect, _ Color)                { c.rects = append(c.rects, rect) }
func (c *recordingCanvas) StrokeRect(Rect, float64, Color)            {}
func (c *recordingCanvas) FillCircle(Vec2, float64, Color)            {}
func (c *recordingCanvas) StrokeCircle(Vec2, float64, float64, Color) {}
func (c *recordingCanvas) StrokeLine(Vec2, Vec2, float64, Color)      {}
func (c *recordingCanvas) DrawText(Vec2, string, Color)               {}
