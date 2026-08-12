//go:build darwin

package platform

import (
	"testing"

	"github.com/gongahkia/72/engine"
)

func TestMacPortableInputMappings(t *testing.T) {
	for code, want := range map[uint16]engine.Key{
		0: engine.KeyA, 49: engine.KeySpace, 123: engine.KeyArrowLeft,
		124: engine.KeyArrowRight, 125: engine.KeyArrowDown, 126: engine.KeyArrowUp,
	} {
		if got, ok := macKey(code); !ok || got != want {
			t.Fatalf("macKey(%d) = %q, %t; want %q, true", code, got, ok, want)
		}
	}
	if _, ok := macKey(0xffff); ok {
		t.Fatal("unmapped macOS key code was accepted")
	}
	if button, ok := macPointerButton(macEventOtherMouseDown, 2); !ok || button != engine.PointerMiddle {
		t.Fatalf("other mouse button = %d, %t", button, ok)
	}
}

func TestMacFocusLossAndUTF16TextAreNormalized(t *testing.T) {
	host := &macHost{state: engine.WindowState{Focused: true}}
	host.appendText(0xd83d)
	host.appendText(0xde80)
	host.setFocus(false)
	events := host.PollEvents()
	if len(events) != 2 || events[0].Kind != engine.EventText || events[0].Text != "🚀" || events[1].Kind != engine.EventFocusChanged || events[1].Focused {
		t.Fatalf("events = %+v", events)
	}
}

func TestMacHostRejectsInvalidConfigBeforeOpeningWindow(t *testing.T) {
	if _, err := newMacHost(engine.Config{Viewport: engine.Size{W: 0, H: 1}, WindowScale: 1}); err == nil {
		t.Fatal("invalid configuration opened a macOS host")
	}
}
