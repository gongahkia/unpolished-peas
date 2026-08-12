//go:build linux

package platform

import (
	"os"
	"testing"

	"github.com/gongahkia/72/engine"
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
}
