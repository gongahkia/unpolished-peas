package engine

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/gongahkia/72/engine/diagnostics"
	"github.com/gongahkia/72/engine/ecs"
	"github.com/gongahkia/72/engine/render"
)

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
	backend := &recordingRenderBackend{}
	if err := runtime.Draw(backend); err != nil {
		t.Fatalf("draw runtime: %v", err)
	}
	if len(backend.frames) != 1 {
		t.Fatalf("runtime frames = %d, want 1", len(backend.frames))
	}
	commands := backend.frames[0].Queue.Commands()
	if len(commands) != 1 || commands[0].Payload.(render.RectDraw).Bounds.X != 4 {
		t.Fatalf("runtime layer commands = %+v", commands)
	}
	metrics := runtime.Diagnostics().Snapshot()
	if !hasRecordedMetric(metrics, "runtime.update_time") || !hasRecordedMetric(metrics, "runtime.draw_time") {
		t.Fatalf("runtime metrics = %+v", metrics)
	}
}

func hasRecordedMetric(metrics []diagnostics.Metric, name string) bool {
	for _, metric := range metrics {
		if metric.Name == name {
			return metric.Count == 1
		}
	}
	return false
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

func TestRuntimeRejectsNilRenderBackend(t *testing.T) {
	runtime, err := NewRuntime(Config{Viewport: Size{W: 320, H: 180}, WindowScale: 1}, &testApplication{})
	if err != nil {
		t.Fatal(err)
	}
	if err := runtime.Draw(nil); err == nil {
		t.Fatal("nil render backend succeeded")
	}
}

func TestRunWithHostInstallsAPlatformContextWithoutGraphicsBinding(t *testing.T) {
	host := &testHost{
		window: &testWindow{state: WindowState{Title: "before", LogicalSize: Size{W: 320, H: 180}, DrawableSize: Size{W: 640, H: 360}, Scale: 2, Focused: true, Visible: true}},
		clock:  testClock{},
		events: &testEvents{events: []Event{{Kind: EventFocusChanged, Focused: true}}},
	}
	app := &hostApplication{}
	if err := RunWithHost(Config{Viewport: Size{W: 320, H: 180}, WindowScale: 1}, app, host); err != nil {
		t.Fatalf("run with host: %v", err)
	}
	if !host.ran || !app.initialized || !app.updated || app.context.Window != host.window || app.context.Clock != host.clock || app.context.Events != host.events {
		t.Fatalf("host lifecycle ran=%t app=%+v context=%+v", host.ran, app, app.context)
	}
	if state := host.window.State(); state.Title != "configured" {
		t.Fatalf("host window state = %+v", state)
	}
}

func TestRuntimeReportsStructuredInitializationAndFrameFailures(t *testing.T) {
	initializeCause := errors.New("game setup failed")
	_, err := NewRuntime(Config{Viewport: Size{W: 320, H: 180}, WindowScale: 1}, failureApplication{initialize: initializeCause})
	assertRuntimeFailure(t, err, diagnostics.RuntimeSubsystem, "initialize application", diagnostics.CorrectConfiguration, true, initializeCause)

	updateCause := errors.New("game update failed")
	runtime, err := NewRuntime(Config{Viewport: Size{W: 320, H: 180}, WindowScale: 1}, failureApplication{update: updateCause})
	if err != nil {
		t.Fatal(err)
	}
	err = runtime.Update(NewInput(nil))
	assertRuntimeFailure(t, err, diagnostics.FrameSubsystem, "update application", diagnostics.CorrectInput, false, updateCause)

	err = RunWithHost(Config{Viewport: Size{W: 320, H: 180}, WindowScale: 1}, &testApplication{}, nil)
	assertRuntimeFailure(t, err, diagnostics.HostSubsystem, "acquire host", diagnostics.CorrectConfiguration, true, nil)
}

func assertRuntimeFailure(t *testing.T, err error, subsystem diagnostics.Subsystem, operation string, recovery diagnostics.Recovery, terminal bool, cause error) {
	t.Helper()
	var failure *diagnostics.Failure
	if !errors.As(err, &failure) {
		t.Fatalf("error %v is not a diagnostics failure", err)
	}
	if failure.Subsystem != subsystem || failure.Operation != operation || failure.Recovery != recovery || failure.Terminal != terminal {
		t.Fatalf("failure = %+v", failure)
	}
	if cause != nil && !errors.Is(err, cause) {
		t.Fatalf("failure %v did not preserve cause %v", err, cause)
	}
}

type testPlugin struct{ built bool }

type failureApplication struct {
	initialize error
	update     error
}

func (a failureApplication) Initialize(*Runtime) error { return a.initialize }

func (a failureApplication) Update(Input) error { return a.update }

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
		DrawCommands: func(frame CommandFrame) error {
			return frame.FillRect(render.RectDraw{Bounds: render.Rect{X: 4, Y: 8, W: 1, H: 1}, Color: render.Color{A: 255}})
		},
	})
}

func (a *testApplication) Update(input Input) error {
	a.updated = input.Pressed("jump")
	return nil
}

type hostApplication struct {
	initialized bool
	updated     bool
	context     HostContext
}

func (a *hostApplication) Initialize(runtime *Runtime) error {
	a.initialized, a.context = true, runtime.Host()
	return a.context.Window.SetTitle("configured")
}

func (a *hostApplication) Update(Input) error {
	a.updated = true
	return nil
}

type testHost struct {
	window *testWindow
	clock  testClock
	events *testEvents
	ran    bool
}

func (h *testHost) Context() HostContext {
	return HostContext{Window: h.window, Clock: h.clock, Events: h.events}
}

func (h *testHost) Run(runtime *Runtime) error {
	h.ran = true
	if events := h.events.PollEvents(); len(events) != 1 || events[0].Kind != EventFocusChanged {
		return fmt.Errorf("fake host event stream = %+v", events)
	}
	return runtime.Update(NewInput(nil))
}

type testWindow struct {
	state     WindowState
	cursor    Cursor
	clipboard string
}

func (w *testWindow) State() WindowState                { return w.state }
func (w *testWindow) SetTitle(title string) error       { w.state.Title = title; return nil }
func (w *testWindow) SetCursor(cursor Cursor) error     { w.cursor = cursor; return nil }
func (w *testWindow) ReadClipboard() (string, error)    { return w.clipboard, nil }
func (w *testWindow) WriteClipboard(value string) error { w.clipboard = value; return nil }

type testClock struct{}

func (testClock) Now() time.Time      { return time.Unix(0, 0) }
func (testClock) Timing() FrameTiming { return FrameTiming{Frame: 1, Delta: time.Second / 60} }

type testEvents struct{ events []Event }

func (e *testEvents) PollEvents() []Event {
	events := append([]Event(nil), e.events...)
	e.events = nil
	return events
}
