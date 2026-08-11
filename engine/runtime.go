package engine

import (
	"fmt"

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
	tick     uint64
}

// NewRuntime creates and initializes an application runtime.
func NewRuntime(config Config, app Application) (*Runtime, error) {
	return newRuntime(config, app, HostContext{})
}

func newRuntime(config Config, app Application, host HostContext) (*Runtime, error) {
	if app == nil {
		return nil, fmt.Errorf("application must not be nil")
	}
	if err := config.validate(); err != nil {
		return nil, err
	}
	runtime := &Runtime{
		config:   config,
		app:      app,
		host:     host,
		camera:   NewCamera(config.Viewport),
		world:    ecs.NewWorld(),
		systems:  ecs.NewSchedule(),
		textures: render.NewTextureStore(),
	}
	for _, plugin := range config.Plugins {
		if plugin == nil {
			return nil, fmt.Errorf("plugin must not be nil")
		}
		if err := plugin.Build(runtime); err != nil {
			return nil, fmt.Errorf("build plugin: %w", err)
		}
	}
	if err := app.Initialize(runtime); err != nil {
		return nil, fmt.Errorf("initialize application: %w", err)
	}
	return runtime, nil
}

// Run initializes an application and delegates the platform event loop to a backend.
func Run(config Config, app Application, backend Backend) error {
	if backend == nil {
		return fmt.Errorf("backend must not be nil")
	}
	runtime, err := NewRuntime(config, app)
	if err != nil {
		return err
	}
	return backend.Run(runtime)
}

// RunWithHost initializes an application with a host-owned platform context
// and delegates event-loop ownership to host. Context is installed before
// Application.Initialize so setup can configure portable window state.
func RunWithHost(config Config, app Application, host Host) error {
	if host == nil {
		return fmt.Errorf("host must not be nil")
	}
	context := host.Context()
	if err := context.validate(); err != nil {
		return err
	}
	runtime, err := newRuntime(config, app, context)
	if err != nil {
		return err
	}
	return host.Run(runtime)
}

// Config returns the immutable runtime configuration.
func (r *Runtime) Config() Config { return r.config }

// Host returns the platform context installed by RunWithHost. It is the zero
// value for runtimes created with NewRuntime or the legacy Run function.
func (r *Runtime) Host() HostContext { return r.host }

// Actions returns the configured input bindings.
func (r *Runtime) Actions() ActionMap { return r.config.Actions }

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
		return err
	}
	if err := r.app.Update(input); err != nil {
		return err
	}
	if err := r.systems.Run(ecs.Update, r.world); err != nil {
		return err
	}
	if err := r.systems.Run(ecs.PostUpdate, r.world); err != nil {
		return err
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
			return err
		}
	}
	return r.systems.Run(ecs.FixedUpdate, r.world)
}

// Draw renders all currently registered layers in order.
func (r *Runtime) Draw(canvas Canvas) error {
	return r.layers.draw(canvas, r.camera, r.tick, r.textures)
}
