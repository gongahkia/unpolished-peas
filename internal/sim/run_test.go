package sim

import (
	"fmt"
	"testing"
)

func TestRunsAreDeterministicReadableAndComplete(t *testing.T) {
	first, second := GenerateRun(0x72), GenerateRun(0x72)
	if !first.Valid || runFingerprint(first) != runFingerprint(second) {
		t.Fatalf("same seed did not generate a stable valid run: %s / %s; issue=%s", first, second, runValidationIssue(&first))
	}
	if runFingerprint(first) == runFingerprint(GenerateRun(0x73)) {
		t.Fatal("different seeds produced identical run layouts")
	}
	for seed := uint64(1); seed <= 1024; seed++ {
		layout := GenerateRun(seed)
		if !layout.Valid || len(layout.Rooms) != RoomCount || len(layout.Spawns) < RoomCount-1 {
			t.Fatalf("seed %d generated an invalid run: %+v", seed, layout)
		}
	}
}

func TestRunKeepsEntrancesAndExitsSafe(t *testing.T) {
	for seed := uint64(1); seed <= 128; seed++ {
		layout := GenerateRun(seed)
		for _, room := range layout.Rooms {
			if !runPositionClear(layout.Terrain, room.Entry) || !runPositionClear(layout.Terrain, room.Exit) {
				t.Fatalf("seed %d made room %d entry or exit unsafe: %+v", seed, room.Index, room)
			}
		}
	}
}

func runFingerprint(layout RunLayout) string {
	fingerprint := layout.String()
	for _, room := range layout.Rooms {
		fingerprint += fmt.Sprintf("/r%d/%d/%d/%d", room.Index, room.Template, room.Variant, room.ThreatBudget)
	}
	for _, terrain := range layout.Terrain {
		fingerprint += fmt.Sprintf("/t%d/%d/%d,%d,%d,%d", terrain.Kind, terrain.HP, q(terrain.Bounds.X), q(terrain.Bounds.Y), q(terrain.Bounds.W), q(terrain.Bounds.H))
	}
	for _, object := range layout.Objects {
		fingerprint += fmt.Sprintf("/o%d/%d/%d,%d", object.ID, object.Kind, q(object.Pos.X), q(object.Pos.Y))
	}
	for _, spawn := range layout.Spawns {
		fingerprint += fmt.Sprintf("/e%d/%d/%d,%d", spawn.Room, spawn.Archetype, q(spawn.Pos.X), q(spawn.Pos.Y))
	}
	return fingerprint
}
