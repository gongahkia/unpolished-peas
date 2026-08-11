package engine

import (
	"fmt"
	"math"
	"sort"
	"unicode/utf8"
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
	if len(b.Keys) > 0 || len(b.GamepadButtons) > 0 {
		return true
	}
	return b.Axis != nil && (len(b.Axis.Negative) > 0 || len(b.Axis.Positive) > 0 || b.Axis.UseGamepad)
}

// ActionMap maps actions to their platform-independent bindings.
type ActionMap map[Action]Binding

// Validate checks that every action has a usable, normalized binding.
func (m ActionMap) Validate() error {
	for action, binding := range m {
		if action == "" {
			return fmt.Errorf("action name must not be empty")
		}
		if !binding.valid() {
			return fmt.Errorf("action %q has no input binding", action)
		}
		for _, key := range append(append([]Key(nil), binding.Keys...), axisKeys(binding.Axis)...) {
			if key == "" {
				return fmt.Errorf("action %q has an empty key binding", action)
			}
		}
		if binding.Axis != nil && (binding.Axis.Deadzone < 0 || binding.Axis.Deadzone >= 1 || math.IsNaN(binding.Axis.Deadzone)) {
			return fmt.Errorf("action %q has invalid axis deadzone %g", action, binding.Axis.Deadzone)
		}
	}
	return nil
}

func axisKeys(binding *AxisBinding) []Key {
	if binding == nil {
		return nil
	}
	return append(append([]Key(nil), binding.Negative...), binding.Positive...)
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

// Clone returns a deep copy of bindings suitable for independent rebinding.
func (m ActionMap) Clone() ActionMap {
	clone := make(ActionMap, len(m))
	for action, binding := range m {
		clone[action] = cloneBinding(binding)
	}
	return clone
}

// Rebind returns a copy of the map with one action replaced by binding.
func (m ActionMap) Rebind(action Action, binding Binding) (ActionMap, error) {
	clone := m.Clone()
	clone[action] = cloneBinding(binding)
	if err := clone.Validate(); err != nil {
		return nil, err
	}
	return clone, nil
}

func cloneBinding(binding Binding) Binding {
	copy := Binding{
		Keys:           append([]Key(nil), binding.Keys...),
		GamepadButtons: append([]GamepadButton(nil), binding.GamepadButtons...),
	}
	if binding.Axis != nil {
		axis := *binding.Axis
		axis.Negative = append([]Key(nil), binding.Axis.Negative...)
		axis.Positive = append([]Key(nil), binding.Axis.Positive...)
		copy.Axis = &axis
	}
	return copy
}

// ActionState is one sampled action for the current update.
type ActionState struct {
	Down     bool
	Pressed  bool
	Released bool
	Value    float64
}

// PointerState is one screen-space pointer snapshot. Buttons is a copy owned
// by Input; callers can use Button for a zero-value-safe lookup.
type PointerState struct {
	Position Vec2
	Delta    Vec2
	Scroll   Vec2
	Buttons  map[PointerButton]ActionState
}

// Button returns one pointer button's state, or the zero value if unseen.
func (p PointerState) Button(button PointerButton) ActionState { return p.Buttons[button] }

// GamepadConnection records a connection change observed in one input sample.
type GamepadConnection struct {
	DeviceID  uint32
	Connected bool
}

// Input exposes normalized action, pointer, text, and gamepad snapshots for
// one update. It contains no host or backend-specific values.
type Input struct {
	states      map[Action]ActionState
	pointer     PointerState
	text        []string
	connections []GamepadConnection
}

// NewInput creates an action-only snapshot. The supplied map is copied; use
// InputMapper when sampling normalized Host events.
func NewInput(states map[Action]ActionState) Input {
	clone := make(map[Action]ActionState, len(states))
	for action, state := range states {
		clone[action] = state
	}
	return Input{states: clone}
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

// Pointer returns a copy of this update's pointer snapshot.
func (i Input) Pointer() PointerState {
	pointer := i.pointer
	pointer.Buttons = copyPointerButtons(i.pointer.Buttons)
	return pointer
}

// Text returns UTF-8 text input committed during this update.
func (i Input) Text() []string { return append([]string(nil), i.text...) }

// GamepadConnections returns connection events observed during this update.
func (i Input) GamepadConnections() []GamepadConnection {
	return append([]GamepadConnection(nil), i.connections...)
}

// InputMapper transforms host-normalized events into portable Input snapshots.
// It is owned by one host event-loop goroutine and is not safe for concurrent
// calls. Equivalent event sequences produce equivalent snapshots across hosts.
type InputMapper struct {
	actions         ActionMap
	previous        map[Action]ActionState
	keys            map[Key]bool
	gamepads        map[uint32]*gamepadState
	pointerPosition Vec2
	pointerButtons  map[PointerButton]bool
	previousPointer map[PointerButton]bool
}

type gamepadState struct {
	buttons map[GamepadButton]bool
	axes    map[GamepadAxis]float64
}

// NewInputMapper validates actions and creates an event mapper with no held
// state. The action map is copied so later caller mutation cannot affect it.
func NewInputMapper(actions ActionMap) (*InputMapper, error) {
	if err := actions.Validate(); err != nil {
		return nil, err
	}
	return &InputMapper{
		actions:         actions.Clone(),
		previous:        make(map[Action]ActionState),
		keys:            make(map[Key]bool),
		gamepads:        make(map[uint32]*gamepadState),
		pointerButtons:  make(map[PointerButton]bool),
		previousPointer: make(map[PointerButton]bool),
	}, nil
}

// Actions returns a copy of the mapper's active bindings.
func (m *InputMapper) Actions() ActionMap {
	if m == nil {
		return nil
	}
	return m.actions.Clone()
}

// SetActions replaces the mapper's action bindings without discarding raw held
// controls. A rebind therefore emits a release when its old source is held or
// a press when its new source is already held.
func (m *InputMapper) SetActions(actions ActionMap) error {
	if m == nil {
		return fmt.Errorf("input mapper must not be nil")
	}
	if err := actions.Validate(); err != nil {
		return err
	}
	m.actions = actions.Clone()
	return nil
}

// Rebind replaces one action binding while preserving other configured actions.
func (m *InputMapper) Rebind(action Action, binding Binding) error {
	if m == nil {
		return fmt.Errorf("input mapper must not be nil")
	}
	actions, err := m.actions.Rebind(action, binding)
	if err != nil {
		return err
	}
	return m.SetActions(actions)
}

// Sample consumes one host event batch and returns its Input snapshot. A
// focus-loss event clears all held raw controls, causing one Released action or
// pointer state where appropriate. Invalid UTF-8 text and non-finite axis
// values are ignored because hosts must not inject malformed normalized input.
func (m *InputMapper) Sample(events []Event) Input {
	if m == nil {
		return NewInput(nil)
	}
	text := make([]string, 0)
	connections := make([]GamepadConnection, 0)
	pointerDelta, pointerScroll := Vec2{}, Vec2{}
	for _, event := range events {
		switch event.Kind {
		case EventKey:
			m.keys[event.Key] = event.Pressed
		case EventText:
			if event.Text != "" && utf8.ValidString(event.Text) {
				text = append(text, event.Text)
			}
		case EventPointerMove:
			if finiteVec2(event.Position) {
				pointerDelta.X += event.Position.X - m.pointerPosition.X
				pointerDelta.Y += event.Position.Y - m.pointerPosition.Y
				m.pointerPosition = event.Position
			}
		case EventPointerButton:
			m.pointerButtons[event.PointerButton] = event.Pressed
		case EventPointerWheel:
			if finiteVec2(event.Scroll) {
				pointerScroll.X += event.Scroll.X
				pointerScroll.Y += event.Scroll.Y
			}
		case EventGamepadConnection:
			connections = append(connections, GamepadConnection{DeviceID: event.DeviceID, Connected: event.Connected})
			if event.Connected {
				m.gamepads[event.DeviceID] = &gamepadState{buttons: make(map[GamepadButton]bool), axes: make(map[GamepadAxis]float64)}
			} else {
				delete(m.gamepads, event.DeviceID)
			}
		case EventGamepadButton:
			m.gamepad(event.DeviceID).buttons[event.Button] = event.Pressed
		case EventGamepadAxis:
			if !math.IsNaN(event.Value) && !math.IsInf(event.Value, 0) {
				m.gamepad(event.DeviceID).axes[event.Axis] = math.Max(-1, math.Min(1, event.Value))
			}
		case EventFocusChanged:
			if !event.Focused {
				m.resetHeld()
			}
		}
	}
	states := make(map[Action]ActionState, len(m.actions))
	for _, action := range m.actions.Actions() {
		down, value := m.bindingState(m.actions[action])
		previous := m.previous[action]
		states[action] = ActionState{Down: down, Pressed: down && !previous.Down, Released: previous.Down && !down, Value: value}
	}
	m.previous = states
	pointer := PointerState{Position: m.pointerPosition, Delta: pointerDelta, Scroll: pointerScroll, Buttons: make(map[PointerButton]ActionState)}
	for _, button := range pointerButtons(m.pointerButtons, m.previousPointer) {
		down, previous := m.pointerButtons[button], m.previousPointer[button]
		pointer.Buttons[button] = ActionState{Down: down, Pressed: down && !previous, Released: previous && !down}
	}
	m.previousPointer = copyPointerHeld(m.pointerButtons)
	return Input{states: states, pointer: pointer, text: text, connections: connections}
}

func (m *InputMapper) gamepad(id uint32) *gamepadState {
	state := m.gamepads[id]
	if state == nil {
		state = &gamepadState{buttons: make(map[GamepadButton]bool), axes: make(map[GamepadAxis]float64)}
		m.gamepads[id] = state
	}
	return state
}

func (m *InputMapper) resetHeld() {
	m.keys = make(map[Key]bool)
	m.gamepads = make(map[uint32]*gamepadState)
	m.pointerButtons = make(map[PointerButton]bool)
}

func (m *InputMapper) bindingState(binding Binding) (bool, float64) {
	down := false
	for _, key := range binding.Keys {
		if m.keys[key] {
			down = true
			break
		}
	}
	for _, gamepad := range m.gamepads {
		for _, button := range binding.GamepadButtons {
			if gamepad.buttons[button] {
				down = true
				break
			}
		}
		if down {
			break
		}
	}
	if binding.Axis == nil {
		return down, 0
	}
	negative, positive := heldKeys(m.keys, binding.Axis.Negative), heldKeys(m.keys, binding.Axis.Positive)
	if negative != positive {
		if negative {
			return true, -1
		}
		return true, 1
	}
	if !binding.Axis.UseGamepad {
		return down, 0
	}
	for _, id := range sortedGamepadIDs(m.gamepads) {
		value := m.gamepads[id].axes[binding.Axis.GamepadAxis]
		if math.Abs(value) > binding.Axis.Deadzone {
			return true, value
		}
	}
	return down, 0
}

func finiteVec2(value Vec2) bool {
	return !math.IsNaN(value.X) && !math.IsInf(value.X, 0) && !math.IsNaN(value.Y) && !math.IsInf(value.Y, 0)
}

func heldKeys(held map[Key]bool, keys []Key) bool {
	for _, key := range keys {
		if held[key] {
			return true
		}
	}
	return false
}

func sortedGamepadIDs(gamepads map[uint32]*gamepadState) []uint32 {
	ids := make([]uint32, 0, len(gamepads))
	for id := range gamepads {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(left, right int) bool { return ids[left] < ids[right] })
	return ids
}

func pointerButtons(current, previous map[PointerButton]bool) []PointerButton {
	buttons := make(map[PointerButton]struct{}, len(current)+len(previous))
	for button := range current {
		buttons[button] = struct{}{}
	}
	for button := range previous {
		buttons[button] = struct{}{}
	}
	result := make([]PointerButton, 0, len(buttons))
	for button := range buttons {
		result = append(result, button)
	}
	sort.Slice(result, func(left, right int) bool { return result[left] < result[right] })
	return result
}

func copyPointerHeld(buttons map[PointerButton]bool) map[PointerButton]bool {
	clone := make(map[PointerButton]bool, len(buttons))
	for button, down := range buttons {
		clone[button] = down
	}
	return clone
}

func copyPointerButtons(buttons map[PointerButton]ActionState) map[PointerButton]ActionState {
	clone := make(map[PointerButton]ActionState, len(buttons))
	for button, state := range buttons {
		clone[button] = state
	}
	return clone
}
