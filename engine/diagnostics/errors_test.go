package diagnostics

import (
	"errors"
	"testing"
)

func TestFailurePreservesCauseAndRecovery(t *testing.T) {
	cause := errors.New("adapter unavailable")
	err := NewFailure(RendererSubsystem, "initialize device", cause, Recreate, true)
	if !errors.Is(err, cause) {
		t.Fatal("failure did not preserve cause")
	}
	var failure *Failure
	if !errors.As(err, &failure) {
		t.Fatal("failure is not discoverable with errors.As")
	}
	if failure.Subsystem != RendererSubsystem || failure.Operation != "initialize device" || failure.Recovery != Recreate || !failure.Terminal {
		t.Fatalf("failure = %+v", failure)
	}
	if got, want := err.Error(), "renderer initialize device failed (terminal; recovery: recreate subsystem): adapter unavailable"; got != want {
		t.Fatalf("failure text = %q, want %q", got, want)
	}
}

func TestRegistryRecordsStructuredFailureBySubsystem(t *testing.T) {
	registry := NewRegistry()
	if err := registry.RecordFailure(NewFailure(AssetsSubsystem, "load asset", errors.New("missing"), CorrectInput, false)); err != nil {
		t.Fatal(err)
	}
	if err := registry.RecordFailure(nil); err != nil {
		t.Fatal(err)
	}
	if err := registry.RecordFailure(errors.New("plain error")); err == nil {
		t.Fatal("plain error was recorded as a structured failure")
	}
	metrics := registry.Snapshot()
	if len(metrics) != 1 || metrics[0].Name != "failure.assets" || metrics[0].Count != 1 {
		t.Fatalf("metrics = %+v", metrics)
	}
}
