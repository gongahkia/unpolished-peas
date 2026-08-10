package engine

import "testing"

import "github.com/gongahkia/72/engine/ecs"

func TestRuntimeOwnsApplicationLifecycle(t *testing.T) {
	app := &testApplication{}
	runtime, err := NewRuntime(Config{
		Viewport:    Size{W: 320, H: 180},
		WindowScale: 1,
		Actions:     ActionMap{Action("jump"): {Keys: []Key{KeySpace}}},
	}, app)
	if err != nil {
		t.Fatalf("new runtime: %v", err)
	}
	if !app.initialized {
		t.Fatal("application was not initialized")
	}
	if err := runtime.Update(NewInput(map[Action]ActionState{Action("jump"): {Pressed: true}})); err != nil {
		t.Fatalf("update runtime: %v", err)
	}
	if !app.updated {
		t.Fatal("application did not receive update input")
	}
	canvas := &recordingCanvas{}
	runtime.Draw(canvas)
	if len(canvas.rects) != 1 || canvas.rects[0].X != 4 {
		t.Fatalf("runtime layer draw = %+v, want one rectangle at X=4", canvas.rects)
	}
}

func TestRuntimeBuildsPluginsAndRunsScheduledSystems(t *testing.T) {
	plugin := &testPlugin{}
	runtime, err := NewRuntime(Config{
		Viewport:    Size{W: 320, H: 180},
		WindowScale: 1,
		Plugins:     []Plugin{plugin},
	}, &testApplication{})
	if err != nil {
		t.Fatalf("new runtime: %v", err)
	}
	if !plugin.built {
		t.Fatal("plugin was not built")
	}
	if err := runtime.Update(NewInput(nil)); err != nil {
		t.Fatal(err)
	}
	if value, ok := ecs.Resource[int](runtime.World()); !ok || value != 2 {
		t.Fatalf("scheduled resource = %d, %t", value, ok)
	}
}

type testPlugin struct{ built bool }

func (p *testPlugin) Build(runtime *Runtime) error {
	p.built = true
	ecs.SetResource(runtime.World(), 1)
	return runtime.Systems().Add(ecs.Update, "increment", func(world *ecs.World) error {
		value, _ := ecs.Resource[int](world)
		ecs.SetResource(world, value+1)
		return nil
	})
}

type testApplication struct {
	initialized bool
	updated     bool
}

func (a *testApplication) Initialize(runtime *Runtime) error {
	a.initialized = true
	return runtime.Layers().Add(Layer{
		ID:    "test",
		Space: ScreenSpace,
		Draw: func(frame Frame) {
			frame.Canvas.FillRect(Rect{X: 4, Y: 8, W: 1, H: 1}, Color{})
		},
	})
}

func (a *testApplication) Update(input Input) error {
	a.updated = input.Pressed("jump")
	return nil
}
