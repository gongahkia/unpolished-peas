package engine

import (
	"reflect"
	"testing"
)

func TestInputMapperNormalizesActionsPointerTextAndGamepads(t *testing.T) {
	mapper, err := NewInputMapper(ActionMap{
		"confirm": {Keys: []Key{KeyEnter}, GamepadButtons: []GamepadButton{2}},
		"move":    {Axis: &AxisBinding{Negative: []Key{KeyA}, Positive: []Key{KeyD}, GamepadAxis: 0, UseGamepad: true, Deadzone: .2}},
	})
	if err != nil {
		t.Fatalf("new input mapper: %v", err)
	}

	input := mapper.Sample([]Event{
		{Kind: EventKey, Key: KeyEnter, Pressed: true},
		{Kind: EventPointerMove, Position: Vec2{X: 10, Y: 20}},
		{Kind: EventPointerButton, PointerButton: PointerPrimary, Pressed: true},
		{Kind: EventPointerMove, Position: Vec2{X: 15, Y: 25}},
		{Kind: EventPointerWheel, Scroll: Vec2{X: 1, Y: -2}},
		{Kind: EventText, Text: "ready"},
		{Kind: EventText, Text: string([]byte{0xff})},
		{Kind: EventGamepadConnection, DeviceID: 7, Connected: true},
		{Kind: EventGamepadButton, DeviceID: 7, Button: 2, Pressed: true},
		{Kind: EventGamepadAxis, DeviceID: 7, Axis: 0, Value: .75},
	})
	if state := input.State("confirm"); !state.Down || !state.Pressed || state.Value != 0 {
		t.Fatalf("confirm state = %+v", state)
	}
	if state := input.State("move"); !state.Down || !state.Pressed || state.Value != .75 {
		t.Fatalf("move state = %+v", state)
	}
	pointer := input.Pointer()
	if pointer.Position != (Vec2{X: 15, Y: 25}) || pointer.Delta != (Vec2{X: 15, Y: 25}) || pointer.Scroll != (Vec2{X: 1, Y: -2}) {
		t.Fatalf("pointer = %+v", pointer)
	}
	if state := pointer.Button(PointerPrimary); !state.Down || !state.Pressed || state.Released {
		t.Fatalf("primary pointer button = %+v", state)
	}
	if got, want := input.Text(), []string{"ready"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("text = %#v, want %#v", got, want)
	}
	if got, want := input.GamepadConnections(), []GamepadConnection{{DeviceID: 7, Connected: true}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("connections = %#v, want %#v", got, want)
	}

	next := mapper.Sample(nil)
	if state := next.State("confirm"); !state.Down || state.Pressed || state.Released {
		t.Fatalf("held confirm state = %+v", state)
	}
	if pointer := next.Pointer(); pointer.Delta != (Vec2{}) || pointer.Scroll != (Vec2{}) || pointer.Button(PointerPrimary).Pressed {
		t.Fatalf("next pointer = %+v", pointer)
	}
}

func TestInputMapperFocusLossReleasesHeldControls(t *testing.T) {
	mapper, err := NewInputMapper(ActionMap{"jump": {Keys: []Key{KeySpace}}})
	if err != nil {
		t.Fatalf("new input mapper: %v", err)
	}
	first := mapper.Sample([]Event{
		{Kind: EventKey, Key: KeySpace, Pressed: true},
		{Kind: EventPointerButton, PointerButton: PointerPrimary, Pressed: true},
	})
	if !first.Pressed("jump") || !first.Pointer().Button(PointerPrimary).Pressed {
		t.Fatalf("initial state = input=%+v pointer=%+v", first.State("jump"), first.Pointer().Button(PointerPrimary))
	}

	lostFocus := mapper.Sample([]Event{{Kind: EventFocusChanged, Focused: false}})
	if state := lostFocus.State("jump"); state.Down || !state.Released {
		t.Fatalf("focus-loss action state = %+v", state)
	}
	if state := lostFocus.Pointer().Button(PointerPrimary); state.Down || !state.Released {
		t.Fatalf("focus-loss pointer state = %+v", state)
	}
	if next := mapper.Sample(nil); next.Released("jump") || next.Pointer().Button(PointerPrimary).Released {
		t.Fatalf("release persisted beyond one sample: action=%+v pointer=%+v", next.State("jump"), next.Pointer().Button(PointerPrimary))
	}
}

func TestInputMapperRebindingPreservesRawStateAndCopiesBindings(t *testing.T) {
	actions := ActionMap{"jump": {Keys: []Key{KeySpace}}}
	mapper, err := NewInputMapper(actions)
	if err != nil {
		t.Fatalf("new input mapper: %v", err)
	}
	actions["jump"].Keys[0] = KeyEnter
	if got := mapper.Actions()["jump"].Keys[0]; got != KeySpace {
		t.Fatalf("mapper action key = %q, want %q", got, KeySpace)
	}
	if !mapper.Sample([]Event{{Kind: EventKey, Key: KeySpace, Pressed: true}}).Pressed("jump") {
		t.Fatal("space press was not mapped")
	}
	if err := mapper.Rebind("jump", Binding{Keys: []Key{KeyEnter}}); err != nil {
		t.Fatalf("rebind: %v", err)
	}
	if state := mapper.Sample(nil).State("jump"); state.Down || !state.Released {
		t.Fatalf("rebinding did not release previous binding: %+v", state)
	}
	if state := mapper.Sample([]Event{{Kind: EventKey, Key: KeyEnter, Pressed: true}}).State("jump"); !state.Down || !state.Pressed {
		t.Fatalf("rebinding did not map new key: %+v", state)
	}
	if _, err := mapper.Actions().Rebind("jump", Binding{Keys: []Key{""}}); err == nil {
		t.Fatal("invalid rebind succeeded")
	}
}

func TestRuntimeSamplesNormalizedEventsAfterRebinding(t *testing.T) {
	runtime, err := NewRuntime(Config{
		Viewport:    Size{W: 320, H: 180},
		WindowScale: 1,
		Actions:     ActionMap{"jump": {Keys: []Key{KeySpace}}},
	}, &testApplication{})
	if err != nil {
		t.Fatalf("new runtime: %v", err)
	}
	if !runtime.SampleInput([]Event{{Kind: EventKey, Key: KeySpace, Pressed: true}}).Pressed("jump") {
		t.Fatal("runtime did not sample initial binding")
	}
	if err := runtime.SetActions(ActionMap{"jump": {Keys: []Key{KeyEnter}}}); err != nil {
		t.Fatalf("set actions: %v", err)
	}
	if state := runtime.SampleInput(nil).State("jump"); state.Down || !state.Released {
		t.Fatalf("runtime rebind state = %+v", state)
	}
	returned := runtime.Actions()
	returned["jump"].Keys[0] = KeySpace
	if got := runtime.Actions()["jump"].Keys[0]; got != KeyEnter {
		t.Fatalf("runtime action copy = %q, want %q", got, KeyEnter)
	}
}

func TestInputMapperProducesEquivalentSnapshotsForEquivalentHostEvents(t *testing.T) {
	actions := ActionMap{
		"jump": {Keys: []Key{KeySpace}},
		"move": {Axis: &AxisBinding{Negative: []Key{KeyA}, Positive: []Key{KeyD}, GamepadAxis: 1, UseGamepad: true, Deadzone: .1}},
	}
	native, err := NewInputMapper(actions)
	if err != nil {
		t.Fatalf("new native mapper: %v", err)
	}
	browser, err := NewInputMapper(actions)
	if err != nil {
		t.Fatalf("new browser mapper: %v", err)
	}
	batches := [][]Event{
		{
			{Kind: EventPointerMove, Position: Vec2{X: 8, Y: 4}},
			{Kind: EventText, Text: "go"},
			{Kind: EventKey, Key: KeySpace, Pressed: true},
		},
		{
			{Kind: EventKey, Key: KeySpace, Pressed: false},
			{Kind: EventGamepadConnection, DeviceID: 1, Connected: true},
			{Kind: EventGamepadAxis, DeviceID: 1, Axis: 1, Value: -.5},
		},
		{{Kind: EventFocusChanged, Focused: false}},
	}
	for index, events := range batches {
		if got, want := native.Sample(events), browser.Sample(events); !reflect.DeepEqual(got, want) {
			t.Fatalf("batch %d mismatch:\n got: %#v\nwant: %#v", index, got, want)
		}
	}
}
