package presentation

import (
	"errors"
	"fmt"
	"reflect"
	"testing"

	"github.com/gongahkia/72/engine/diagnostics"
)

func TestManagerConfiguresResizesAndPresents(t *testing.T) {
	driver := &fakeDriver{}
	manager := NewManager(driver)
	if result, err := manager.Resize(Size{Width: 640, Height: 360}); err != nil || !result.Reconfigured {
		t.Fatalf("initial resize = %+v, %v", result, err)
	}
	if result, err := manager.Frame(); err != nil || !result.Presented {
		t.Fatalf("initial frame = %+v, %v", result, err)
	}
	if result, err := manager.Resize(Size{Width: 800, Height: 450}); err != nil || !result.Reconfigured {
		t.Fatalf("resize = %+v, %v", result, err)
	}
	if result, err := manager.Frame(); err != nil || !result.Presented {
		t.Fatalf("resized frame = %+v, %v", result, err)
	}
	want := []string{"open", "configure:640x360", "acquire", "present", "configure:800x450", "acquire", "present"}
	if !reflect.DeepEqual(driver.calls, want) {
		t.Fatalf("driver calls = %v, want %v", driver.calls, want)
	}
}

func TestManagerSuspendsZeroSizedSurface(t *testing.T) {
	driver := &fakeDriver{}
	manager := NewManager(driver)
	if _, err := manager.Resize(Size{Width: 640, Height: 360}); err != nil {
		t.Fatal(err)
	}
	if result, err := manager.Resize(Size{Width: 0, Height: 360}); err != nil || !result.Skipped || manager.State() != StateSuspended {
		t.Fatalf("suspend = %+v, %v, state=%v", result, err, manager.State())
	}
	if result, err := manager.Frame(); err != nil || !result.Skipped {
		t.Fatalf("suspended frame = %+v, %v", result, err)
	}
	want := []string{"open", "configure:640x360"}
	if !reflect.DeepEqual(driver.calls, want) {
		t.Fatalf("driver calls = %v, want %v", driver.calls, want)
	}
}

func TestManagerRecoversAcquireAndPresentFaults(t *testing.T) {
	tests := []struct {
		name     string
		driver   *fakeDriver
		wantCall []string
		want     FrameResult
	}{
		{
			name:     "timeout skips without reconfiguration",
			driver:   &fakeDriver{acquire: []Fault{{Kind: FaultTimeout}}},
			wantCall: []string{"open", "configure:640x360", "acquire", "acquire", "present"},
			want:     FrameResult{Skipped: true},
		},
		{
			name:     "outdated acquire reconfigures",
			driver:   &fakeDriver{acquire: []Fault{{Kind: FaultSurfaceOutdated}}},
			wantCall: []string{"open", "configure:640x360", "acquire", "configure:640x360", "acquire", "present"},
			want:     FrameResult{Skipped: true, Reconfigured: true},
		},
		{
			name:     "lost surface at present reconfigures",
			driver:   &fakeDriver{present: []Fault{{Kind: FaultSurfaceLost}}},
			wantCall: []string{"open", "configure:640x360", "acquire", "present", "configure:640x360", "acquire", "present"},
			want:     FrameResult{Skipped: true, Reconfigured: true},
		},
		{
			name:     "lost device recreates",
			driver:   &fakeDriver{present: []Fault{{Kind: FaultDeviceLost}}},
			wantCall: []string{"open", "configure:640x360", "acquire", "present", "release", "open", "configure:640x360", "acquire", "present"},
			want:     FrameResult{Skipped: true, Reconfigured: true, Recreated: true},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			manager := NewManager(test.driver)
			if _, err := manager.Resize(Size{Width: 640, Height: 360}); err != nil {
				t.Fatal(err)
			}
			result, err := manager.Frame()
			if err != nil {
				t.Fatal(err)
			}
			if result != test.want {
				t.Fatalf("frame result = %+v, want %+v", result, test.want)
			}
			if result, err := manager.Frame(); err != nil || !result.Presented {
				t.Fatalf("recovered frame = %+v, %v", result, err)
			}
			if !reflect.DeepEqual(test.driver.calls, test.wantCall) {
				t.Fatalf("driver calls = %v, want %v", test.driver.calls, test.wantCall)
			}
			if manager.State() != StateReady {
				t.Fatalf("state = %v, want ready", manager.State())
			}
		})
	}
}

func TestManagerReturnsTerminalOutOfMemoryFailure(t *testing.T) {
	cause := errors.New("native allocation exhausted")
	driver := &fakeDriver{acquire: []Fault{{Kind: FaultOutOfMemory, Cause: cause}}}
	manager := NewManager(driver)
	if _, err := manager.Resize(Size{Width: 640, Height: 360}); err != nil {
		t.Fatal(err)
	}
	_, err := manager.Frame()
	assertRendererFailure(t, err, "acquire surface frame", diagnostics.Restart, true, cause)
	if manager.State() != StateFailed {
		t.Fatalf("state = %v, want failed", manager.State())
	}
	_, err = manager.Frame()
	assertRendererFailure(t, err, "acquire surface frame", diagnostics.Restart, true, cause)
}

func TestManagerCloseIsIdempotentAndRejectsNewFrames(t *testing.T) {
	driver := &fakeDriver{}
	manager := NewManager(driver)
	if _, err := manager.Resize(Size{Width: 640, Height: 360}); err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Frame(); err == nil {
		t.Fatal("frame after close succeeded")
	}
	want := []string{"open", "configure:640x360", "release"}
	if !reflect.DeepEqual(driver.calls, want) {
		t.Fatalf("driver calls = %v, want %v", driver.calls, want)
	}
}

func TestManagerRejectsNegativePresentationSize(t *testing.T) {
	manager := NewManager(&fakeDriver{})
	if _, err := manager.Resize(Size{Width: -1, Height: 1}); err == nil {
		t.Fatal("negative size succeeded")
	}
}

func assertRendererFailure(t *testing.T, err error, operation string, recovery diagnostics.Recovery, terminal bool, cause error) {
	t.Helper()
	var failure *diagnostics.Failure
	if !errors.As(err, &failure) {
		t.Fatalf("error %v is not a renderer failure", err)
	}
	if failure.Subsystem != diagnostics.RendererSubsystem || failure.Operation != operation || failure.Recovery != recovery || failure.Terminal != terminal {
		t.Fatalf("failure = %+v", failure)
	}
	if !errors.Is(err, cause) {
		t.Fatalf("failure %v does not retain %v", err, cause)
	}
}

type fakeDriver struct {
	open, configure, acquire, present, release []Fault
	calls                                      []string
}

func (d *fakeDriver) Open() Fault {
	d.calls = append(d.calls, "open")
	return takeFault(&d.open)
}

func (d *fakeDriver) Configure(size Size) Fault {
	d.calls = append(d.calls, "configure:"+sizeText(size))
	return takeFault(&d.configure)
}

func (d *fakeDriver) Acquire() Fault {
	d.calls = append(d.calls, "acquire")
	return takeFault(&d.acquire)
}

func (d *fakeDriver) Present() Fault {
	d.calls = append(d.calls, "present")
	return takeFault(&d.present)
}

func (d *fakeDriver) Release() Fault {
	d.calls = append(d.calls, "release")
	return takeFault(&d.release)
}

func takeFault(faults *[]Fault) Fault {
	if len(*faults) == 0 {
		return Fault{}
	}
	fault := (*faults)[0]
	*faults = (*faults)[1:]
	return fault
}

func sizeText(size Size) string { return fmt.Sprintf("%dx%d", size.Width, size.Height) }
