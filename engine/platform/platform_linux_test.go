//go:build linux

package platform

import (
	"os"
	"testing"

	"github.com/gongahkia/72/engine"
	"github.com/jezek/xgb/xproto"
)

func TestXlibOpenDisplay(t *testing.T) {
	if os.Getenv("DISPLAY") == "" {
		t.Skip("DISPLAY is not available")
	}
	xlib, err := openXlib()
	if err != nil {
		t.Fatal(err)
	}
	defer xlib.close()
	if xlib.display == 0 {
		t.Fatal("XOpenDisplay returned a null display")
	}
	t.Logf("display=%#x", xlib.display)
}

func TestX11HostCreatesNativeWindow(t *testing.T) {
	if os.Getenv("DISPLAY") == "" {
		t.Skip("DISPLAY is not available")
	}
	host, err := newX11Host(engine.Config{
		Title:       "72 platform smoke test",
		Viewport:    engine.Size{W: 64, H: 64},
		WindowScale: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer host.close()
	if host.windowID == 0 || host.renderer == nil {
		t.Fatalf("window=%#x renderer=%v", host.windowID, host.renderer)
	}
	for _, cursor := range []engine.Cursor{engine.CursorDefault, engine.CursorPointer, engine.CursorText, engine.CursorCrosshair} {
		if err := host.SetCursor(cursor); err != nil {
			t.Fatalf("SetCursor(%d): %v", cursor, err)
		}
	}
}

func TestX11CursorRolesHaveCoreGlyphs(t *testing.T) {
	for cursor, want := range map[engine.Cursor]uint16{
		engine.CursorDefault:   xCursorDefault,
		engine.CursorPointer:   xCursorHand,
		engine.CursorText:      xCursorText,
		engine.CursorCrosshair: xCursorCrosshair,
	} {
		if got, ok := xCursorGlyph(cursor); !ok || got != want {
			t.Fatalf("xCursorGlyph(%d) = %d, %t; want %d, true", cursor, got, ok, want)
		}
	}
	if _, ok := xCursorGlyph(engine.CursorHidden); ok {
		t.Fatal("hidden X11 cursor was unexpectedly accepted")
	}
}

func TestX11PhysicalKeycodesUseLocationsInsteadOfKeysyms(t *testing.T) {
	for code, want := range map[uint8]engine.Key{24: engine.KeyQ, 38: engine.KeyA, 50: engine.KeyShiftLeft, 62: engine.KeyShiftRight, 113: engine.KeyArrowLeft, 119: engine.KeyDelete} {
		if got, ok := xKeycode(xproto.Keycode(code)); !ok || got != want {
			t.Fatalf("xKeycode(%d) = %q, %t; want %q, true", code, got, ok, want)
		}
	}
}
