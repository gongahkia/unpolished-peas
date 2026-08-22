package main

import "testing"

func TestLayerPositionUsesDepthRelativeToCamera(t *testing.T) {
	if got, want := layerPosition(384, 160, .25), 344.0; got != want {
		t.Fatalf("deep layer position = %f, want %f", got, want)
	}
	if got, want := layerPosition(384, 160, 1.1), 208.0; got != want {
		t.Fatalf("foreground layer position = %f, want %f", got, want)
	}
}

func TestEnvironmentHashIsStableAndSeedSensitive(t *testing.T) {
	first := environmentHash(72, 4, 8)
	if got := environmentHash(72, 4, 8); got != first {
		t.Fatalf("same environment inputs produced %d, want %d", got, first)
	}
	if got := environmentHash(73, 4, 8); got == first {
		t.Fatal("different environment seed produced the same hash")
	}
}
