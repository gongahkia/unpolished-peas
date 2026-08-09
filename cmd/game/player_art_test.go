package main

import (
	"bytes"
	"image"
	"testing"

	"github.com/gongahkia/72/internal/sim"
)

func TestPlayerVisualMapsEveryTraversalStateToItsOwnPose(t *testing.T) {
	tests := []struct {
		state sim.TraversalState
		want  int
	}{
		{sim.TraversalGrounded, 0},
		{sim.TraversalAirborne, 4},
		{sim.TraversalWallCling, 10},
		{sim.TraversalRolling, 8},
		{sim.TraversalDiving, 15},
		{sim.TraversalLedgeGrab, 13},
		{sim.TraversalMantling, 14},
	}
	for _, test := range tests {
		player := sim.PlayerSnapshot{State: test.state, Facing: 1, Velocity: sim.Vec{Y: -4}, AirJumps: 1}
		if got := playerVisualFor(player, 0).frame; got != test.want {
			t.Errorf("state %s selected frame %d, want %d", test.state, got, test.want)
		}
	}
}

func TestPlayerVisualUsesCrouchAndRunningFrames(t *testing.T) {
	crouching := sim.PlayerSnapshot{State: sim.TraversalGrounded, Facing: 1, Crouching: true}
	if got := playerVisualFor(crouching, 0).frame; got != 9 {
		t.Fatalf("crouching player selected frame %d, want 9", got)
	}
	running := sim.PlayerSnapshot{State: sim.TraversalGrounded, Facing: 1, Velocity: sim.Vec{X: 3}}
	if got := playerVisualFor(running, 0).frame; got != 2 {
		t.Fatalf("running player selected frame %d, want 2", got)
	}
	if got := playerVisualFor(running, 6).frame; got != 3 {
		t.Fatalf("running player did not alternate frames: got %d, want 3", got)
	}
	ledge := sim.PlayerSnapshot{State: sim.TraversalLedgeGrab, Facing: -1}
	if got := playerVisualFor(ledge, 0).facing; got != -1 {
		t.Fatalf("ledge grab lost the player's facing direction: got %d, want -1", got)
	}
}

func TestPlayerAtlasUsesTheExpectedFourByFourGrid(t *testing.T) {
	atlas, _, err := image.Decode(bytes.NewReader(playerAtlasPNG))
	if err != nil {
		t.Fatalf("decode embedded player atlas: %v", err)
	}
	if got, want := atlas.Bounds().Dx(), playerAtlasColumns*playerFrameSize; got != want {
		t.Fatalf("atlas width = %d, want %d", got, want)
	}
	if got, want := atlas.Bounds().Dy(), playerAtlasColumns*playerFrameSize; got != want {
		t.Fatalf("atlas height = %d, want %d", got, want)
	}
	if _, _, _, alpha := atlas.At(0, 0).RGBA(); alpha != 0 {
		t.Fatalf("atlas corner is opaque: alpha = %d", alpha)
	}
}
