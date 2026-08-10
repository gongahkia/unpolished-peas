package engine

import (
	"fmt"
	"sort"
)

// Action identifies an application-defined input action.
type Action string

// Key identifies a backend-neutral keyboard key.
type Key string

const (
	KeyA          Key = "a"
	KeyD          Key = "d"
	KeyE          Key = "e"
	KeyJ          Key = "j"
	KeyP          Key = "p"
	KeyS          Key = "s"
	KeyW          Key = "w"
	KeySpace      Key = "space"
	KeyShift      Key = "shift"
	KeyEnter      Key = "enter"
	KeyPeriod     Key = "period"
	KeyTab        Key = "tab"
	KeyArrowDown  Key = "arrow-down"
	KeyArrowLeft  Key = "arrow-left"
	KeyArrowRight Key = "arrow-right"
	KeyArrowUp    Key = "arrow-up"
	KeyF1         Key = "f1"
	KeyF2         Key = "f2"
	KeyF6         Key = "f6"
)

// GamepadButton identifies a backend-neutral gamepad button.
type GamepadButton uint8

// GamepadAxis identifies a backend-neutral gamepad axis.
type GamepadAxis uint8

// AxisBinding combines digital keys and a gamepad axis into one signed action.
type AxisBinding struct {
	Negative    []Key
	Positive    []Key
	GamepadAxis GamepadAxis
	UseGamepad  bool
	Deadzone    float64
}

// Binding describes the sources for one action. A binding can contain button
// sources, an axis source, or both.
type Binding struct {
	Keys           []Key
	GamepadButtons []GamepadButton
	Axis           *AxisBinding
}

func (b Binding) valid() bool {
	return len(b.Keys) > 0 || len(b.GamepadButtons) > 0 || b.Axis != nil
}

// ActionMap maps actions to their platform-independent bindings.
type ActionMap map[Action]Binding

// Validate checks that every action has a usable binding.
func (m ActionMap) Validate() error {
	for action, binding := range m {
		if action == "" {
			return fmt.Errorf("action name must not be empty")
		}
		if !binding.valid() {
			return fmt.Errorf("action %q has no input binding", action)
		}
		if binding.Axis != nil && (binding.Axis.Deadzone < 0 || binding.Axis.Deadzone >= 1) {
			return fmt.Errorf("action %q has invalid axis deadzone %g", action, binding.Axis.Deadzone)
		}
	}
	return nil
}

// Actions returns action IDs in stable lexical order.
func (m ActionMap) Actions() []Action {
	actions := make([]Action, 0, len(m))
	for action := range m {
		actions = append(actions, action)
	}
	sort.Slice(actions, func(i, j int) bool { return actions[i] < actions[j] })
	return actions
}

// ActionState is one sampled action for the current update.
type ActionState struct {
	Down     bool
	Pressed  bool
	Released bool
	Value    float64
}

// Input exposes the sampled action states for one update.
type Input struct{ states map[Action]ActionState }

// NewInput creates an input snapshot. The supplied map is copied.
func NewInput(states map[Action]ActionState) Input {
	copy := make(map[Action]ActionState, len(states))
	for action, state := range states {
		copy[action] = state
	}
	return Input{states: copy}
}

// State returns an action state, or the zero value for an unknown action.
func (i Input) State(action Action) ActionState { return i.states[action] }

// Down reports whether an action is held.
func (i Input) Down(action Action) bool { return i.State(action).Down }

// Pressed reports whether an action started this update.
func (i Input) Pressed(action Action) bool { return i.State(action).Pressed }

// Released reports whether an action ended this update.
func (i Input) Released(action Action) bool { return i.State(action).Released }

// Axis returns an action's signed analog value.
func (i Input) Axis(action Action) float64 { return i.State(action).Value }
