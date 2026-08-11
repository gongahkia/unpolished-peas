package engine

import (
	"fmt"

	"github.com/gongahkia/72/engine/diagnostics"
	"github.com/gongahkia/72/engine/ecs"
	"github.com/gongahkia/72/engine/render"
)

// Application supplies game-specific behavior to an engine runtime.
type Application interface {
	Initialize(*Runtime) error
	Update(Input) error
}

// FixedApplication is an optional fixed-timestep simulation hook. A backend
// that owns a separate simulation clock calls Runtime.FixedUpdate; the current
// Ebitengine adapter keeps its existing one-update-per-tick behavior.
type FixedApplication interface {
	FixedUpdate(Input) error
}

// Plugin extends a Runtime during initialization. Plugins should register
// components, resources, or scheduled systems through Runtime's public APIs.
type Plugin interface {
	Build(*Runtime) error
}

// Backend hosts the platform event loop for a runtime.
type Backend interface {
	Run(*Runtime) error
}

// Runtime owns application lifecycle state shared by all backends.
type Runtime struct {
	config   Config
	app      Application
	host     HostContext
	camera   Camera
	layers   LayerStack
	world    *ecs.World
	systems  *ecs.Schedule
	textures *render.TextureStore
	input    *InputMapper
	tick     uint64
}

// NewRuntime creates and initializes an application runtime.
func NewRuntime(config Config, app Application) (*Runtime, error) {
	return newRuntime(config, app, HostContext{})
}

func newRuntime(config Config, app Application, host HostContext) (*Runtime, error) {
	if app == nil {
		return nil, runtimeFailure("initialize application", fmt.Errorf("application must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	if err := config.validate(); err != nil {
		return nil, runtimeFailure("validate configuration", err, diagnostics.CorrectConfiguration, true)
	}
	config.Actions = config.Actions.Clone()
	config.Plugins = append([]Plugin(nil), config.Plugins...)
	input, err := NewInputMapper(config.Actions)
	if err != nil {
		return nil, runtimeFailure("initialize input mapper", err, diagnostics.CorrectConfiguration, true)
	}
	runtime := &Runtime{
		config:   config,
		app:      app,
		host:     host,
		camera:   NewCamera(config.Viewport),
		world:    ecs.NewWorld(),
		systems:  ecs.NewSchedule(),
		textures: render.NewTextureStore(),
		input:    input,
	}
	for _, plugin := range config.Plugins {
		if plugin == nil {
			return nil, runtimeFailure("build plugin", fmt.Errorf("plugin must not be nil"), diagnostics.CorrectConfiguration, true)
		}
		if err := plugin.Build(runtime); err != nil {
			return nil, runtimeFailure("build plugin", err, diagnostics.CorrectConfiguration, true)
		}
	}
	if err := app.Initialize(runtime); err != nil {
		return nil, runtimeFailure("initialize application", err, diagnostics.CorrectConfiguration, true)
	}
	return runtime, nil
}

// Run initializes an application and delegates the platform event loop to a backend.
func Run(config Config, app Application, backend Backend) error {
	if backend == nil {
		return hostFailure("run backend", fmt.Errorf("backend must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	runtime, err := NewRuntime(config, app)
	if err != nil {
		return err
	}
	if err := backend.Run(runtime); err != nil {
		return hostFailure("run backend", err, diagnostics.Restart, true)
	}
	return nil
}

// RunWithHost initializes an application with a host-owned platform context
// and delegates event-loop ownership to host. Context is installed before
// Application.Initialize so setup can configure portable window state.
func RunWithHost(config Config, app Application, host Host) error {
	if host == nil {
		return hostFailure("acquire host", fmt.Errorf("host must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	context := host.Context()
	if err := context.validate(); err != nil {
		return hostFailure("validate host context", err, diagnostics.CorrectConfiguration, true)
	}
	runtime, err := newRuntime(config, app, context)
	if err != nil {
		return err
	}
	if err := host.Run(runtime); err != nil {
		return hostFailure("run host", err, diagnostics.Restart, true)
	}
	return nil
}

// Config returns a copy of the immutable runtime configuration.
func (r *Runtime) Config() Config {
	config := r.config
	config.Actions = config.Actions.Clone()
	config.Plugins = append([]Plugin(nil), config.Plugins...)
	return config
}

// Host returns the platform context installed by RunWithHost. It is the zero
// value for runtimes created with NewRuntime or the legacy Run function.
func (r *Runtime) Host() HostContext { return r.host }

// Actions returns a copy of the runtime's active input bindings.
func (r *Runtime) Actions() ActionMap { return r.input.Actions() }

// SetActions replaces the runtime's configurable action bindings. Held raw
// controls are preserved, so the following SampleInput reports the appropriate
// press or release transition for a rebinding.
func (r *Runtime) SetActions(actions ActionMap) error {
	if err := r.input.SetActions(actions); err != nil {
		return err
	}
	r.config.Actions = actions.Clone()
	return nil
}

// SampleInput transforms normalized host events into one portable input
// snapshot. Host implementations should pass their event batch to this method
// before each Update or FixedUpdate call; games receive only the resulting
// Input value.
func (r *Runtime) SampleInput(events []Event) Input { return r.input.Sample(events) }

// Camera returns the mutable runtime camera.
func (r *Runtime) Camera() *Camera { return &r.camera }

// Layers returns the mutable ordered layer stack.
func (r *Runtime) Layers() *LayerStack { return &r.layers }

// World returns the runtime's ECS world. It is the authoritative engine-owned
// storage for entities, components, and resources.
func (r *Runtime) World() *ecs.World { return r.world }

// Systems returns the runtime's deterministic system schedule.
func (r *Runtime) Systems() *ecs.Schedule { return r.systems }

// Textures returns engine-owned portable texture sources for high-level render
// layers. Backends create and cache their own native GPU resources from them.
func (r *Runtime) Textures() *render.TextureStore { return r.textures }

// Update advances the application one platform update.
func (r *Runtime) Update(input Input) error {
	if err := r.systems.Run(ecs.PreUpdate, r.world); err != nil {
		return frameFailure("run pre-update systems", err)
	}
	if err := r.app.Update(input); err != nil {
		return frameFailure("update application", err)
	}
	if err := r.systems.Run(ecs.Update, r.world); err != nil {
		return frameFailure("run update systems", err)
	}
	if err := r.systems.Run(ecs.PostUpdate, r.world); err != nil {
		return frameFailure("run post-update systems", err)
	}
	r.tick++
	return nil
}

// FixedUpdate advances optional fixed simulation behavior and fixed systems.
// It does not increment the presentation tick; a backend controls how fixed
// and presentation clocks relate.
func (r *Runtime) FixedUpdate(input Input) error {
	if app, ok := r.app.(FixedApplication); ok {
		if err := app.FixedUpdate(input); err != nil {
			return frameFailure("fixed update application", err)
		}
	}
	if err := r.systems.Run(ecs.FixedUpdate, r.world); err != nil {
		return frameFailure("run fixed-update systems", err)
	}
	return nil
}

// Draw renders all currently registered layers in order.
func (r *Runtime) Draw(canvas Canvas) error {
	if err := r.layers.draw(canvas, r.camera, r.tick, r.textures); err != nil {
		return frameFailure("draw layers", err)
	}
	return nil
}

func runtimeFailure(operation string, cause error, recovery diagnostics.Recovery, terminal bool) error {
	return diagnostics.NewFailure(diagnostics.RuntimeSubsystem, operation, cause, recovery, terminal)
}

func hostFailure(operation string, cause error, recovery diagnostics.Recovery, terminal bool) error {
	return diagnostics.NewFailure(diagnostics.HostSubsystem, operation, cause, recovery, terminal)
}

func frameFailure(operation string, cause error) error {
	return diagnostics.NewFailure(diagnostics.FrameSubsystem, operation, cause, diagnostics.CorrectInput, false)
}
