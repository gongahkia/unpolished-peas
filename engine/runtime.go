package engine

import "fmt"

// Application supplies game-specific behavior to an engine runtime.
type Application interface {
	Initialize(*Runtime) error
	Update(Input) error
}

// Backend hosts the platform event loop for a runtime.
type Backend interface {
	Run(*Runtime) error
}

// Runtime owns application lifecycle state shared by all backends.
type Runtime struct {
	config Config
	app    Application
	camera Camera
	layers LayerStack
	tick   uint64
}

// NewRuntime creates and initializes an application runtime.
func NewRuntime(config Config, app Application) (*Runtime, error) {
	if app == nil {
		return nil, fmt.Errorf("application must not be nil")
	}
	if err := config.validate(); err != nil {
		return nil, err
	}
	runtime := &Runtime{config: config, app: app, camera: NewCamera(config.Viewport)}
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

// Config returns the immutable runtime configuration.
func (r *Runtime) Config() Config { return r.config }

// Actions returns the configured input bindings.
func (r *Runtime) Actions() ActionMap { return r.config.Actions }

// Camera returns the mutable runtime camera.
func (r *Runtime) Camera() *Camera { return &r.camera }

// Layers returns the mutable ordered layer stack.
func (r *Runtime) Layers() *LayerStack { return &r.layers }

// Update advances the application one platform update.
func (r *Runtime) Update(input Input) error {
	if err := r.app.Update(input); err != nil {
		return err
	}
	r.tick++
	return nil
}

// Draw renders all currently registered layers in order.
func (r *Runtime) Draw(canvas Canvas) { r.layers.draw(canvas, r.camera, r.tick) }
