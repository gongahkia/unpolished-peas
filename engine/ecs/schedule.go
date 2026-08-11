package ecs

import (
	"fmt"
	"reflect"
)

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

// System updates one World. Systems in the same phase execute in resolved
// deterministic order; an error stops the phase at the nearest useful boundary.
type System func(*World) error

// Target identifies a component or singleton resource for access declarations.
// Construct targets with ComponentTarget or ResourceTarget; the zero value is
// invalid.
type Target struct {
	component bool
	typeID    reflect.Type
}

// ComponentTarget returns the access target for components of type T.
func ComponentTarget[T any]() Target {
	return Target{component: true, typeID: typeOf[T]()}
}

// ResourceTarget returns the access target for singleton resources of type T.
func ResourceTarget[T any]() Target {
	return Target{typeID: typeOf[T]()}
}

func (t Target) String() string {
	if t.typeID == nil {
		return "invalid target"
	}
	if t.component {
		return "component " + t.typeID.String()
	}
	return "resource " + t.typeID.String()
}

// Access declares which component and resource targets a system reads or
// writes. A target listed in both sets is treated as a write. Access metadata
// is validation information only: the scheduler remains serial.
type Access struct {
	Reads  []Target
	Writes []Target
}

// SystemSpec describes one system and its explicit ordering requirements.
// Before and After name systems in the same phase. All names must already be
// registered when the spec is added, which keeps schedule failures local to
// the registration that introduced them.
type SystemSpec struct {
	Name   string
	Run    System
	Access Access
	Before []string
	After  []string
}

type registeredSystem struct {
	spec  SystemSpec
	index uint64
}

// Schedule owns deterministic system phases for one World.
type Schedule struct {
	phases map[Phase][]registeredSystem
	next   uint64
}

// NewSchedule creates an empty schedule.
func NewSchedule() *Schedule { return &Schedule{phases: make(map[Phase][]registeredSystem)} }

// Add registers a legacy named system in phase. It preserves registration
// order and declares no accesses. New code that reads or writes shared world
// state should use AddSystem.
func (s *Schedule) Add(phase Phase, name string, run System) error {
	return s.AddSystem(phase, SystemSpec{Name: name, Run: run})
}

// AddSystem registers a declared system. Conflicting accesses in one phase
// require an explicit Before or After path; read-only overlap is allowed.
func (s *Schedule) AddSystem(phase Phase, spec SystemSpec) error {
	if spec.Name == "" {
		return fmt.Errorf("system name must not be empty")
	}
	if spec.Run == nil {
		return fmt.Errorf("system %q must not be nil", spec.Name)
	}
	if err := validateAccess(spec.Access); err != nil {
		return fmt.Errorf("system %q: %w", spec.Name, err)
	}
	for _, system := range s.phases[phase] {
		if system.spec.Name == spec.Name {
			return fmt.Errorf("system %q is already registered in phase %d", spec.Name, phase)
		}
	}
	spec.Before = append([]string(nil), spec.Before...)
	spec.After = append([]string(nil), spec.After...)
	candidate := append(append([]registeredSystem(nil), s.phases[phase]...), registeredSystem{spec: spec, index: s.next})
	if _, err := ordered(candidate); err != nil {
		return fmt.Errorf("register system %q: %w", spec.Name, err)
	}
	s.phases[phase] = candidate
	s.next++
	return nil
}

// Validate checks ordering references, cycles, and declared conflicts in
// phase. It is useful after constructing a schedule before handing it to a
// host; AddSystem performs the same validation at each registration.
func (s *Schedule) Validate(phase Phase) error {
	_, err := ordered(s.phases[phase])
	return err
}

// Run executes a phase in resolved deterministic order.
func (s *Schedule) Run(phase Phase, world *World) error {
	systems, err := ordered(s.phases[phase])
	if err != nil {
		return fmt.Errorf("validate phase %d: %w", phase, err)
	}
	for _, system := range systems {
		if err := system.spec.Run(world); err != nil {
			return fmt.Errorf("run system %q: %w", system.spec.Name, err)
		}
	}
	return nil
}

// Names returns registered system names in execution order. Invalid schedules
// return nil; AddSystem normally prevents that state from being created.
func (s *Schedule) Names(phase Phase) []string {
	systems, err := ordered(s.phases[phase])
	if err != nil {
		return nil
	}
	names := make([]string, len(systems))
	for index, system := range systems {
		names[index] = system.spec.Name
	}
	return names
}

func validateAccess(access Access) error {
	for _, target := range append(append([]Target(nil), access.Reads...), access.Writes...) {
		if target.typeID == nil {
			return fmt.Errorf("access target must be created with ComponentTarget or ResourceTarget")
		}
	}
	return nil
}

func ordered(systems []registeredSystem) ([]registeredSystem, error) {
	byName := make(map[string]int, len(systems))
	for index, system := range systems {
		if system.spec.Name == "" {
			return nil, fmt.Errorf("system at index %d has an empty name", index)
		}
		if _, exists := byName[system.spec.Name]; exists {
			return nil, fmt.Errorf("system %q is registered more than once", system.spec.Name)
		}
		if system.spec.Run == nil {
			return nil, fmt.Errorf("system %q must not be nil", system.spec.Name)
		}
		if err := validateAccess(system.spec.Access); err != nil {
			return nil, fmt.Errorf("system %q: %w", system.spec.Name, err)
		}
		byName[system.spec.Name] = index
	}

	edges := make([]map[int]struct{}, len(systems))
	for index := range edges {
		edges[index] = make(map[int]struct{})
	}
	for index, system := range systems {
		for _, name := range system.spec.Before {
			target, ok := byName[name]
			if !ok {
				return nil, fmt.Errorf("system %q orders before unknown system %q", system.spec.Name, name)
			}
			edges[index][target] = struct{}{}
		}
		for _, name := range system.spec.After {
			target, ok := byName[name]
			if !ok {
				return nil, fmt.Errorf("system %q orders after unknown system %q", system.spec.Name, name)
			}
			edges[target][index] = struct{}{}
		}
	}
	for first := range systems {
		for second := first + 1; second < len(systems); second++ {
			if !conflicts(systems[first].spec.Access, systems[second].spec.Access) {
				continue
			}
			if reachable(edges, first, second) || reachable(edges, second, first) {
				continue
			}
			return nil, fmt.Errorf("systems %q and %q have conflicting declared access; add Before or After", systems[first].spec.Name, systems[second].spec.Name)
		}
	}

	indegree := make([]int, len(systems))
	for _, next := range edges {
		for target := range next {
			indegree[target]++
		}
	}
	result := make([]registeredSystem, 0, len(systems))
	used := make([]bool, len(systems))
	for range systems {
		next := -1
		for index, system := range systems {
			if !used[index] && indegree[index] == 0 && (next < 0 || system.index < systems[next].index) {
				next = index
			}
		}
		if next < 0 {
			return nil, fmt.Errorf("system ordering contains a cycle")
		}
		used[next] = true
		result = append(result, systems[next])
		for target := range edges[next] {
			indegree[target]--
		}
	}
	return result, nil
}

func conflicts(first, second Access) bool {
	firstWrites := targetSet(first.Writes)
	secondWrites := targetSet(second.Writes)
	for target := range firstWrites {
		if secondWrites[target] || targetSet(second.Reads)[target] {
			return true
		}
	}
	for target := range secondWrites {
		if targetSet(first.Reads)[target] {
			return true
		}
	}
	return false
}

func targetSet(targets []Target) map[Target]bool {
	set := make(map[Target]bool, len(targets))
	for _, target := range targets {
		set[target] = true
	}
	return set
}

func reachable(edges []map[int]struct{}, start, target int) bool {
	seen := make([]bool, len(edges))
	stack := []int{start}
	for len(stack) > 0 {
		index := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if index == target {
			return true
		}
		if seen[index] {
			continue
		}
		seen[index] = true
		for next := range edges[index] {
			if !seen[next] {
				stack = append(stack, next)
			}
		}
	}
	return false
}
