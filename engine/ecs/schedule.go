package ecs

import "fmt"

// Phase identifies an ordered stage in one runtime tick.
type Phase uint8

const (
	// PreUpdate runs before application update behavior.
	PreUpdate Phase = iota
	// Update runs after application update behavior.
	Update
	// PostUpdate runs after Update systems.
	PostUpdate
	// FixedUpdate is reserved for hosts that advance a fixed simulation clock.
	FixedUpdate
)

// System updates one World. Systems in the same phase execute in registration
// order; an error stops the phase at the nearest useful boundary.
type System func(*World) error

type registeredSystem struct {
	name string
	run  System
}

// Schedule owns deterministic system phases for one World.
type Schedule struct{ phases map[Phase][]registeredSystem }

// NewSchedule creates an empty schedule.
func NewSchedule() *Schedule { return &Schedule{phases: make(map[Phase][]registeredSystem)} }

// Add registers a named system in phase. Names are unique within a phase.
func (s *Schedule) Add(phase Phase, name string, run System) error {
	if name == "" {
		return fmt.Errorf("system name must not be empty")
	}
	if run == nil {
		return fmt.Errorf("system %q must not be nil", name)
	}
	for _, system := range s.phases[phase] {
		if system.name == name {
			return fmt.Errorf("system %q is already registered in phase %d", name, phase)
		}
	}
	s.phases[phase] = append(s.phases[phase], registeredSystem{name: name, run: run})
	return nil
}

// Run executes a phase in registration order.
func (s *Schedule) Run(phase Phase, world *World) error {
	for _, system := range s.phases[phase] {
		if err := system.run(world); err != nil {
			return fmt.Errorf("run system %q: %w", system.name, err)
		}
	}
	return nil
}

// Names returns registered system names in execution order.
func (s *Schedule) Names(phase Phase) []string {
	systems := s.phases[phase]
	names := make([]string, len(systems))
	for index, system := range systems {
		names[index] = system.name
	}
	return names
}
