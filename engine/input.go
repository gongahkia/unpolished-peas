package engine

import (
	"fmt"
	"math"
	"sort"
	"unicode/utf8"
)

// Action identifies an application-defined input action.
type Action string

// Key identifies a backend-neutral physical keyboard key. Hosts map the
// location of a key rather than the character produced by the active layout.
type Key string

const (
	KeyA Key = "a"
	KeyB Key = "b"
	KeyC Key = "c"
	KeyD Key = "d"
	KeyE Key = "e"
	KeyF Key = "f"
	KeyG Key = "g"
	KeyH Key = "h"
	KeyI Key = "i"
	KeyJ Key = "j"
	KeyK Key = "k"
	KeyL Key = "l"
	KeyM Key = "m"
	KeyN Key = "n"
	KeyO Key = "o"
	KeyP Key = "p"
	KeyQ Key = "q"
	KeyR Key = "r"
	KeyS Key = "s"
	KeyT Key = "t"
	KeyU Key = "u"
	KeyV Key = "v"
	KeyW Key = "w"
	KeyX Key = "x"
	KeyY Key = "y"
	KeyZ Key = "z"

	KeyDigit0 Key = "digit-0"
	KeyDigit1 Key = "digit-1"
	KeyDigit2 Key = "digit-2"
	KeyDigit3 Key = "digit-3"
	KeyDigit4 Key = "digit-4"
	KeyDigit5 Key = "digit-5"
	KeyDigit6 Key = "digit-6"
	KeyDigit7 Key = "digit-7"
	KeyDigit8 Key = "digit-8"
	KeyDigit9 Key = "digit-9"

	KeyBackquote     Key = "backquote"
	KeyBackslash     Key = "backslash"
	KeyBracketLeft   Key = "bracket-left"
	KeyBracketRight  Key = "bracket-right"
	KeyComma         Key = "comma"
	KeyEqual         Key = "equal"
	KeyIntlBackslash Key = "intl-backslash"
	KeyMinus         Key = "minus"
	KeyPeriod        Key = "period"
	KeyQuote         Key = "quote"
	KeySemicolon     Key = "semicolon"
	KeySlash         Key = "slash"

	KeyAltLeft      Key = "alt-left"
	KeyAltRight     Key = "alt-right"
	KeyBackspace    Key = "backspace"
	KeyCapsLock     Key = "caps-lock"
	KeyContextMenu  Key = "context-menu"
	KeyControlLeft  Key = "control-left"
	KeyControlRight Key = "control-right"
	KeyEnter        Key = "enter"
	KeyMetaLeft     Key = "meta-left"
	KeyMetaRight    Key = "meta-right"
	KeyShiftLeft    Key = "shift-left"
	KeyShiftRight   Key = "shift-right"
	KeySpace        Key = "space"
	KeyTab          Key = "tab"

	KeyDelete     Key = "delete"
	KeyEnd        Key = "end"
	KeyHelp       Key = "help"
	KeyHome       Key = "home"
	KeyInsert     Key = "insert"
	KeyPageDown   Key = "page-down"
	KeyPageUp     Key = "page-up"
	KeyArrowDown  Key = "arrow-down"
	KeyArrowLeft  Key = "arrow-left"
	KeyArrowRight Key = "arrow-right"
	KeyArrowUp    Key = "arrow-up"

	KeyNumLock        Key = "num-lock"
	KeyNumpad0        Key = "numpad-0"
	KeyNumpad1        Key = "numpad-1"
	KeyNumpad2        Key = "numpad-2"
	KeyNumpad3        Key = "numpad-3"
	KeyNumpad4        Key = "numpad-4"
	KeyNumpad5        Key = "numpad-5"
	KeyNumpad6        Key = "numpad-6"
	KeyNumpad7        Key = "numpad-7"
	KeyNumpad8        Key = "numpad-8"
	KeyNumpad9        Key = "numpad-9"
	KeyNumpadAdd      Key = "numpad-add"
	KeyNumpadDecimal  Key = "numpad-decimal"
	KeyNumpadDivide   Key = "numpad-divide"
	KeyNumpadEnter    Key = "numpad-enter"
	KeyNumpadEqual    Key = "numpad-equal"
	KeyNumpadMultiply Key = "numpad-multiply"
	KeyNumpadSubtract Key = "numpad-subtract"

	KeyEscape      Key = "escape"
	KeyF1          Key = "f1"
	KeyF2          Key = "f2"
	KeyF3          Key = "f3"
	KeyF4          Key = "f4"
	KeyF5          Key = "f5"
	KeyF6          Key = "f6"
	KeyF7          Key = "f7"
	KeyF8          Key = "f8"
	KeyF9          Key = "f9"
	KeyF10         Key = "f10"
	KeyF11         Key = "f11"
	KeyF12         Key = "f12"
	KeyPause       Key = "pause"
	KeyPrintScreen Key = "print-screen"
	KeyScrollLock  Key = "scroll-lock"

	// KeyShift is retained as an aggregate compatibility binding. Host events
	// always use KeyShiftLeft or KeyShiftRight when that distinction exists.
	KeyShift Key = "shift"
)

// GamepadButton identifies a button in the W3C standard gamepad mapping.
type GamepadButton uint8

const (
	GamepadButtonSouth GamepadButton = iota
	GamepadButtonEast
	GamepadButtonWest
	GamepadButtonNorth
	GamepadButtonLeftBumper
	GamepadButtonRightBumper
	GamepadButtonLeftTrigger
	GamepadButtonRightTrigger
	GamepadButtonSelect
	GamepadButtonStart
	GamepadButtonLeftStick
	GamepadButtonRightStick
	GamepadButtonDPadUp
	GamepadButtonDPadDown
	GamepadButtonDPadLeft
	GamepadButtonDPadRight
	GamepadButtonHome
)

// GamepadAxis identifies an axis in the W3C standard gamepad mapping.
type GamepadAxis uint8

const (
	GamepadAxisLeftStickX GamepadAxis = iota
	GamepadAxisLeftStickY
	GamepadAxisRightStickX
	GamepadAxisRightStickY
)

// GamepadMapping identifies the layout semantics reported for a controller.
// Only standard-mapped controllers can produce normalized button and axis
// events; unsupported layouts remain observable through connection events.
type GamepadMapping uint8

const (
	GamepadMappingStandard GamepadMapping = iota
	GamepadMappingUnknown
)

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
	Mapping   GamepadMapping
	Supported bool
}

// Gamepad is one ordered standard-profile controller snapshot. Buttons use
// [0,1], while axes use [-1,1]. Maps are copies owned by Input.
type Gamepad struct {
	DeviceID uint32
	Mapping  GamepadMapping
	Buttons  map[GamepadButton]float64
	Axes     map[GamepadAxis]float64
}

// CompositionPhase identifies an IME preedit lifecycle transition.
type CompositionPhase uint8

const (
	CompositionStart CompositionPhase = iota
	CompositionUpdate
	CompositionEnd
)

// CompositionEvent is an IME preedit transition observed during one sample.
// End is marked Canceled when focus changes before text is committed.
type CompositionEvent struct {
	Phase    CompositionPhase
	Text     string
	Canceled bool
}

// Input exposes normalized action, pointer, text, composition, and gamepad
// snapshots for one update. It contains no host or backend-specific values.
type Input struct {
	states      map[Action]ActionState
	pointer     PointerState
	text        []string
	composition []CompositionEvent
	preedit     string
	composing   bool
	connections []GamepadConnection
	gamepads    []Gamepad
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

// Composition returns preedit transitions observed during this update.
func (i Input) Composition() []CompositionEvent {
	return append([]CompositionEvent(nil), i.composition...)
}

// Preedit returns the current uncommitted IME text and whether a composition
// remains active after this update.
func (i Input) Preedit() (string, bool) { return i.preedit, i.composing }

// GamepadConnections returns connection events observed during this update.
func (i Input) GamepadConnections() []GamepadConnection {
	return append([]GamepadConnection(nil), i.connections...)
}

// Gamepads returns ordered, standard-profile controller snapshots. Unknown or
// unavailable controller mappings produce no snapshots and remain visible via
// GamepadConnections instead.
func (i Input) Gamepads() []Gamepad {
	gamepads := make([]Gamepad, len(i.gamepads))
	for index, gamepad := range i.gamepads {
		gamepads[index] = Gamepad{
			DeviceID: gamepad.DeviceID,
			Mapping:  gamepad.Mapping,
			Buttons:  copyGamepadButtons(gamepad.Buttons),
			Axes:     copyGamepadAxes(gamepad.Axes),
		}
	}
	return gamepads
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
	preedit         string
	composing       bool
}

type gamepadState struct {
	mapping GamepadMapping
	buttons map[GamepadButton]float64
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
// focus-loss event clears held raw controls and cancels an active composition,
// causing one Released action or pointer state where appropriate. Invalid UTF-8
// text and non-finite analog values are ignored because hosts must not inject
// malformed normalized input.
func (m *InputMapper) Sample(events []Event) Input {
	if m == nil {
		return NewInput(nil)
	}
	text := make([]string, 0)
	composition := make([]CompositionEvent, 0)
	connections := make([]GamepadConnection, 0)
	pointerDelta, pointerScroll := Vec2{}, Vec2{}
	for _, event := range events {
		switch event.Kind {
		case EventKey:
			if event.Key != "" {
				m.keys[event.Key] = event.Pressed
			}
		case EventText:
			if event.Text != "" && utf8.ValidString(event.Text) {
				text = append(text, event.Text)
			}
		case EventComposition:
			if event.Text != "" && !utf8.ValidString(event.Text) {
				continue
			}
			switch event.Composition {
			case CompositionStart:
				m.composing, m.preedit = true, event.Text
				composition = append(composition, CompositionEvent{Phase: CompositionStart, Text: event.Text})
			case CompositionUpdate:
				m.composing, m.preedit = true, event.Text
				composition = append(composition, CompositionEvent{Phase: CompositionUpdate, Text: event.Text})
			case CompositionEnd:
				composition = append(composition, CompositionEvent{Phase: CompositionEnd, Text: event.Text, Canceled: event.CompositionCanceled})
				m.composing, m.preedit = false, ""
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
			supported := !event.GamepadUnsupported && event.GamepadMapping == GamepadMappingStandard
			connections = append(connections, GamepadConnection{DeviceID: event.DeviceID, Connected: event.Connected, Mapping: event.GamepadMapping, Supported: supported})
			if event.Connected {
				if supported {
					m.gamepads[event.DeviceID] = &gamepadState{mapping: event.GamepadMapping, buttons: make(map[GamepadButton]float64), axes: make(map[GamepadAxis]float64)}
				} else {
					delete(m.gamepads, event.DeviceID)
				}
			} else {
				delete(m.gamepads, event.DeviceID)
			}
		case EventGamepadButton:
			value := event.Value
			if event.Pressed && value == 0 {
				value = 1
			}
			if !event.Pressed {
				value = 0
			}
			if finite(value) {
				m.gamepad(event.DeviceID).buttons[event.Button] = clamp(value, 0, 1)
			}
		case EventGamepadAxis:
			if finite(event.Value) {
				m.gamepad(event.DeviceID).axes[event.Axis] = clamp(event.Value, -1, 1)
			}
		case EventFocusChanged:
			if !event.Focused {
				if m.composing {
					composition = append(composition, CompositionEvent{Phase: CompositionEnd, Text: m.preedit, Canceled: true})
					m.composing, m.preedit = false, ""
				}
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
	return Input{states: states, pointer: pointer, text: text, composition: composition, preedit: m.preedit, composing: m.composing, connections: connections, gamepads: m.gamepadSnapshots()}
}

func (m *InputMapper) gamepad(id uint32) *gamepadState {
	state := m.gamepads[id]
	if state == nil {
		state = &gamepadState{mapping: GamepadMappingStandard, buttons: make(map[GamepadButton]float64), axes: make(map[GamepadAxis]float64)}
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
	value := 0.0
	for _, key := range binding.Keys {
		if heldKey(m.keys, key) {
			down = true
			value = 1
			break
		}
	}
	for _, gamepad := range m.gamepads {
		for _, button := range binding.GamepadButtons {
			if buttonValue := gamepad.buttons[button]; buttonValue >= .5 {
				down = true
				value = math.Max(value, buttonValue)
			}
		}
		if down {
			break
		}
	}
	if binding.Axis == nil {
		return down, value
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
	return down, value
}

func finiteVec2(value Vec2) bool {
	return !math.IsNaN(value.X) && !math.IsInf(value.X, 0) && !math.IsNaN(value.Y) && !math.IsInf(value.Y, 0)
}

func heldKeys(held map[Key]bool, keys []Key) bool {
	for _, key := range keys {
		if heldKey(held, key) {
			return true
		}
	}
	return false
}

func heldKey(held map[Key]bool, key Key) bool {
	if key == KeyShift {
		return held[KeyShift] || held[KeyShiftLeft] || held[KeyShiftRight]
	}
	return held[key]
}

func (m *InputMapper) gamepadSnapshots() []Gamepad {
	ids := sortedGamepadIDs(m.gamepads)
	gamepads := make([]Gamepad, 0, len(ids))
	for _, id := range ids {
		state := m.gamepads[id]
		gamepads = append(gamepads, Gamepad{DeviceID: id, Mapping: state.mapping, Buttons: copyGamepadButtons(state.buttons), Axes: copyGamepadAxes(state.axes)})
	}
	return gamepads
}

func copyGamepadButtons(buttons map[GamepadButton]float64) map[GamepadButton]float64 {
	clone := make(map[GamepadButton]float64, len(buttons))
	for button, value := range buttons {
		clone[button] = value
	}
	return clone
}

func copyGamepadAxes(axes map[GamepadAxis]float64) map[GamepadAxis]float64 {
	clone := make(map[GamepadAxis]float64, len(axes))
	for axis, value := range axes {
		clone[axis] = value
	}
	return clone
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func clamp(value, minimum, maximum float64) float64 {
	return math.Max(minimum, math.Min(maximum, value))
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
