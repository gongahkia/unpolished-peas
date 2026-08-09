package main

import (
	"testing"

	"github.com/gongahkia/72/internal/sim"
)

func TestFollowCameraClampsToWorldBounds(t *testing.T) {
	if camera := followCamera(sim.Vec{X: 10, Y: 10}); camera != (sim.Vec{}) {
		t.Fatalf("camera escaped upper-left bound: %+v", camera)
	}
	if camera := followCamera(sim.Vec{X: sim.ArenaW - 5, Y: sim.ArenaH - 5}); camera != (sim.Vec{X: sim.ArenaW - float64(logicalW), Y: sim.ArenaH - float64(logicalH)}) {
		t.Fatalf("camera escaped lower-right bound: %+v", camera)
	}
	if camera := followCamera(sim.Vec{X: 900, Y: 500}); camera != (sim.Vec{X: 580, Y: 320}) {
		t.Fatalf("camera did not center inside the world: %+v", camera)
	}
}
