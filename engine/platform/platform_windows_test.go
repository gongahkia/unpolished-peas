//go:build windows

package platform

import (
	"testing"

	"github.com/gongahkia/72/engine"
	"golang.org/x/sys/windows"
)

func TestWin32PortableInputMappings(t *testing.T) {
	for virtual, want := range map[uintptr]engine.Key{
		0x41: engine.KeyA, 0x20: engine.KeySpace, 0x25: engine.KeyArrowLeft,
		0x26: engine.KeyArrowUp, 0x27: engine.KeyArrowRight, 0x28: engine.KeyArrowDown,
	} {
		if got, ok := win32Key(virtual); !ok || got != want {
			t.Fatalf("win32Key(%#x) = %q, %t; want %q, true", virtual, got, ok, want)
		}
	}
	if _, ok := win32Key(0); ok {
		t.Fatal("unmapped virtual key was accepted")
	}
	for _, test := range []struct {
		virtual uintptr
		lparam  uintptr
		want    engine.Key
	}{
		{virtual: 0x10, lparam: 0x2a << 16, want: engine.KeyShiftLeft},
		{virtual: 0x10, lparam: 0x36 << 16, want: engine.KeyShiftRight},
		{virtual: 0x11, lparam: 0x1d << 16, want: engine.KeyControlLeft},
		{virtual: 0x11, lparam: 0x1d<<16 | 1<<24, want: engine.KeyControlRight},
		{virtual: 0x25, lparam: 0x4b<<16 | 1<<24, want: engine.KeyArrowLeft},
	} {
		if got, ok := win32KeyEvent(test.virtual, test.lparam); !ok || got != test.want {
			t.Fatalf("win32KeyEvent(%#x, %#x) = %q, %t; want %q, true", test.virtual, test.lparam, got, ok, test.want)
		}
	}
	gamepad := win32GamepadFromXInput(win32XInputGamepad{Buttons: 0x1001, LeftTrigger: 128, ThumbLY: -32768})
	if gamepad.buttons[engine.GamepadButtonSouth] != 1 || gamepad.buttons[engine.GamepadButtonDPadUp] != 1 || gamepad.buttons[engine.GamepadButtonLeftTrigger] <= .5 || gamepad.axes[engine.GamepadAxisLeftStickY] != 1 {
		t.Fatalf("XInput gamepad = %+v", gamepad)
	}
	negative := int16(-9)
	if point := win32PointFromLParam(uintptr(uint16(12)) | uintptr(uint16(negative))<<16); point != (win32Point{X: 12, Y: -9}) {
		t.Fatalf("Win32 pointer = %+v", point)
	}
}

func TestWin32PointerPositionsUseLogicalPixels(t *testing.T) {
	host := &win32Host{
		config: engine.Config{Viewport: engine.Size{W: 320, H: 180}},
		state:  engine.WindowState{DrawableSize: engine.Size{W: 640, H: 360}},
	}
	if got := host.logicalPointerPosition(win32Point{X: 100, Y: 50}); got != (engine.Vec2{X: 50, Y: 25}) {
		t.Fatalf("logical pointer position = %+v", got)
	}
}

func TestWin32FocusLossAndUTF16TextAreNormalized(t *testing.T) {
	host := &win32Host{state: engine.WindowState{Focused: true}}
	host.appendText(0xd83d)
	host.appendText(0xde80)
	host.setFocus(false)
	events := host.PollEvents()
	if len(events) != 2 || events[0].Kind != engine.EventText || events[0].Text != "🚀" || events[1].Kind != engine.EventFocusChanged || events[1].Focused {
		t.Fatalf("events = %+v", events)
	}
}

func TestWin32UTF16ClipboardText(t *testing.T) {
	if got := windows.UTF16ToString([]uint16{'7', '2', 0, 'x'}); got != "72" {
		t.Fatalf("clipboard text = %q", got)
	}
}

func TestWin32HostRejectsInvalidConfigBeforeOpeningWindow(t *testing.T) {
	if _, err := newWin32Host(engine.Config{Viewport: engine.Size{W: 0, H: 1}, WindowScale: 1}); err == nil {
		t.Fatal("invalid configuration opened a Win32 host")
	}
}
