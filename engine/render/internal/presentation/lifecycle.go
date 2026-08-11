// Package presentation contains the private, backend-neutral GPU presentation
// lifecycle policy. A chosen renderer maps binding-specific failures to Fault
// at this boundary; no binding type may cross it.
package presentation

import (
	"fmt"

	"github.com/gongahkia/72/engine/diagnostics"
)

// Size is a physical presentation extent. A zero dimension is a suspended
// surface, such as a minimized desktop window or a zero-sized browser canvas.
type Size struct{ Width, Height int }

func (s Size) valid() bool { return s.Width >= 0 && s.Height >= 0 }
func (s Size) empty() bool { return s.Width == 0 || s.Height == 0 }

// FaultKind classifies a binding-specific presentation result. Drivers retain
// their original cause in Fault.Cause, but the policy itself remains binding
// agnostic.
type FaultKind uint8

const (
	FaultNone FaultKind = iota
	FaultTimeout
	FaultSurfaceOutdated
	FaultSurfaceLost
	FaultDeviceLost
	FaultOutOfMemory
	FaultFatal
)

func (k FaultKind) String() string {
	switch k {
	case FaultNone:
		return "no fault"
	case FaultTimeout:
		return "presentation timeout"
	case FaultSurfaceOutdated:
		return "outdated surface"
	case FaultSurfaceLost:
		return "lost surface"
	case FaultDeviceLost:
		return "lost device"
	case FaultOutOfMemory:
		return "out of memory"
	case FaultFatal:
		return "fatal presentation failure"
	default:
		return fmt.Sprintf("unknown presentation fault %d", k)
	}
}

// Fault is the normalized result of a private driver operation. FaultNone
// indicates success. Cause is optional for deterministic statuses such as a
// timeout, but a driver should retain its native error whenever one exists.
type Fault struct {
	Kind  FaultKind
	Cause error
}

// Driver is implemented by the private binding adapter on its render thread.
// Open includes adapter selection and device creation. Release must make its
// current surface/device resources unavailable and be safe after a failed or
// partially completed Open; the manager calls it both on device loss and final
// shutdown.
type Driver interface {
	Open() Fault
	Configure(Size) Fault
	Acquire() Fault
	Present() Fault
	Release() Fault
}

// State reports the manager's private lifecycle state. It is observable only
// to renderer-internal tests and future private backends.
type State uint8

const (
	StateNew State = iota
	StateReady
	StateSuspended
	StateFailed
	StateClosed
)

// FrameResult reports deterministic non-error recovery without claiming a GPU
// frame was presented. Reconfigured and Recreated mean the operation happened
// during this call; callers should submit a new frame after Skipped is true.
type FrameResult struct {
	Presented    bool
	Skipped      bool
	Reconfigured bool
	Recreated    bool
}

// Manager owns the policy for one private presentation driver. It is not safe
// for concurrent use: the selected host must call it only from its render
// thread, together with the private GPU resource cache.
type Manager struct {
	driver     Driver
	size       Size
	state      State
	device     bool
	configured bool
	terminal   error
}

// NewManager creates a presentation lifecycle manager. The driver is opened
// lazily when Resize provides a non-empty drawable size.
func NewManager(driver Driver) *Manager {
	return &Manager{driver: driver, state: StateNew}
}

// State returns the current private lifecycle state.
func (m *Manager) State() State { return m.state }

// Resize records the latest physical drawable size and configures the surface
// immediately when it is usable. A zero dimension suspends presentation rather
// than issuing an invalid GPU surface configuration.
func (m *Manager) Resize(size Size) (FrameResult, error) {
	if err := m.available("resize presentation surface"); err != nil {
		return FrameResult{}, err
	}
	if !size.valid() {
		return FrameResult{}, diagnostics.NewFailure(diagnostics.RendererSubsystem, "resize presentation surface", fmt.Errorf("presentation size must not be negative: %dx%d", size.Width, size.Height), diagnostics.CorrectInput, false)
	}
	changed := m.size != size
	m.size = size
	if size.empty() {
		m.configured = false
		m.state = StateSuspended
		return FrameResult{Skipped: true}, nil
	}
	if changed {
		m.configured = false
	}
	if !changed && m.configured {
		return FrameResult{}, nil
	}
	return m.prepare()
}

// Frame acquires and presents one frame. Timeouts, outdated surfaces, and
// device loss are recovered deterministically and report Skipped. Out of
// memory and unclassified failures return structured renderer errors.
func (m *Manager) Frame() (FrameResult, error) {
	if err := m.available("present frame"); err != nil {
		return FrameResult{}, err
	}
	if m.size.empty() {
		m.state = StateSuspended
		return FrameResult{Skipped: true}, nil
	}
	if !m.configured {
		if result, err := m.prepare(); err != nil {
			return result, err
		}
	}
	if fault := m.driver.Acquire(); fault.Kind != FaultNone {
		return m.handleFrameFault("acquire surface frame", fault)
	}
	if fault := m.driver.Present(); fault.Kind != FaultNone {
		return m.handleFrameFault("present surface frame", fault)
	}
	return FrameResult{Presented: true}, nil
}

// Close releases private resources and permanently rejects later Resize or
// Frame calls. It is idempotent after a successful close.
func (m *Manager) Close() error {
	if m.state == StateClosed {
		return nil
	}
	if m.state == StateFailed {
		return m.terminal
	}
	if err := m.release("release presentation resources"); err != nil {
		return err
	}
	m.state = StateClosed
	return nil
}

func (m *Manager) prepare() (FrameResult, error) {
	result := FrameResult{}
	if m.size.empty() {
		m.configured = false
		m.state = StateSuspended
		return FrameResult{Skipped: true}, nil
	}
	if !m.device {
		if fault := m.driver.Open(); fault.Kind != FaultNone {
			return result, m.nonFrameFault("select adapter and create device", fault)
		}
		m.device = true
	}
	if m.configured {
		m.state = StateReady
		return result, nil
	}
	if fault := m.driver.Configure(m.size); fault.Kind != FaultNone {
		return m.configureFault(fault)
	}
	m.configured = true
	m.state = StateReady
	result.Reconfigured = true
	return result, nil
}

func (m *Manager) handleFrameFault(operation string, fault Fault) (FrameResult, error) {
	switch fault.Kind {
	case FaultTimeout:
		return FrameResult{Skipped: true}, nil
	case FaultSurfaceOutdated, FaultSurfaceLost:
		result, err := m.reconfigure()
		result.Skipped = true
		return result, err
	case FaultDeviceLost:
		result, err := m.recreate()
		result.Skipped = true
		return result, err
	default:
		return FrameResult{}, m.nonFrameFault(operation, fault)
	}
}

func (m *Manager) configureFault(fault Fault) (FrameResult, error) {
	switch fault.Kind {
	case FaultDeviceLost:
		return m.recreate()
	default:
		return FrameResult{}, m.nonFrameFault("configure presentation surface", fault)
	}
}

func (m *Manager) reconfigure() (FrameResult, error) {
	m.configured = false
	if fault := m.driver.Configure(m.size); fault.Kind != FaultNone {
		if fault.Kind == FaultDeviceLost {
			return m.recreate()
		}
		return FrameResult{}, m.nonFrameFault("reconfigure presentation surface", fault)
	}
	m.configured = true
	m.state = StateReady
	return FrameResult{Reconfigured: true}, nil
}

func (m *Manager) recreate() (FrameResult, error) {
	if err := m.release("release lost device"); err != nil {
		return FrameResult{}, err
	}
	m.device, m.configured, m.state = false, false, StateNew
	result, err := m.prepare()
	result.Recreated = true
	return result, err
}

func (m *Manager) release(operation string) error {
	if m.driver == nil {
		return diagnostics.NewFailure(diagnostics.RendererSubsystem, operation, fmt.Errorf("presentation driver must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	if fault := m.driver.Release(); fault.Kind != FaultNone {
		return m.nonFrameFault(operation, fault)
	}
	m.device, m.configured = false, false
	return nil
}

func (m *Manager) available(operation string) error {
	if m.driver == nil {
		return diagnostics.NewFailure(diagnostics.RendererSubsystem, operation, fmt.Errorf("presentation driver must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	if m.state == StateClosed {
		return diagnostics.NewFailure(diagnostics.RendererSubsystem, operation, fmt.Errorf("presentation manager is closed"), diagnostics.Restart, true)
	}
	if m.state == StateFailed {
		return m.terminal
	}
	return nil
}

func (m *Manager) nonFrameFault(operation string, fault Fault) error {
	recovery, terminal := diagnostics.Restart, true
	switch fault.Kind {
	case FaultTimeout, FaultSurfaceOutdated, FaultSurfaceLost:
		recovery, terminal = diagnostics.Retry, false
	case FaultDeviceLost:
		recovery, terminal = diagnostics.Recreate, false
	case FaultOutOfMemory:
		recovery, terminal = diagnostics.Restart, true
	}
	cause := fault.Cause
	if cause == nil {
		cause = fmt.Errorf("%s", fault.Kind)
	}
	err := diagnostics.NewFailure(diagnostics.RendererSubsystem, operation, cause, recovery, terminal)
	if terminal {
		m.state, m.terminal = StateFailed, err
	}
	return err
}
