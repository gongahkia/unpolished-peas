//go:build linux

package platform

import (
	"math"
	"testing"

	"github.com/gongahkia/72/engine"
)

func TestEvdevNormalizesStandardControls(t *testing.T) {
	gamepad := &evdevGamepad{id: 4}
	events := make([]engine.Event, 0)
	gamepad.apply(evdevEvent{Type: evdevEventKey, Code: evdevButtonSouth, Value: 1}, &events)
	gamepad.apply(evdevEvent{Type: evdevEventAbs, Code: evdevAbsHat0X, Value: -1}, &events)
	if gamepad.buttons[engine.GamepadButtonSouth] != 1 || gamepad.buttons[engine.GamepadButtonDPadLeft] != 1 || gamepad.buttons[engine.GamepadButtonDPadRight] != 0 {
		t.Fatalf("evdev state = %+v", gamepad.buttons)
	}
	if len(events) != 2 || events[0].Button != engine.GamepadButtonSouth || events[1].Button != engine.GamepadButtonDPadLeft {
		t.Fatalf("evdev events = %+v", events)
	}
	gamepad.apply(evdevEvent{Type: evdevEventKey, Code: evdevButtonSouth, Value: 1}, &events)
	if len(events) != 2 {
		t.Fatalf("repeat event produced a duplicate: %+v", events)
	}
}

func TestEvdevNormalizesAxisAndTriggerRanges(t *testing.T) {
	axis := evdevAbsInfo{Minimum: -32768, Maximum: 32767}
	if got := evdevNormalizeAxisWithValue(axis, -32768); got != -1 {
		t.Fatalf("minimum axis = %g", got)
	}
	if got := evdevNormalizeAxisWithValue(axis, 32767); got != 1 {
		t.Fatalf("maximum axis = %g", got)
	}
	trigger := evdevAbsInfo{Minimum: 0, Maximum: 255}
	if got := evdevNormalizeTrigger(trigger, 128); math.Abs(got-128.0/255.0) > 1e-9 {
		t.Fatalf("trigger = %g", got)
	}
	if request := evdevIOCGetBits(evdevEventKey, 96); request == 0 {
		t.Fatal("EVIOCGBIT request is zero")
	}
}
