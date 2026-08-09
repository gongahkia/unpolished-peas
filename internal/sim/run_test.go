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

func TestRunWorldCollectsTreasureAndKeepsRunStateInTheHash(t *testing.T) {
	world := NewRunWorld(0x72)
	var treasure *WorldObject
	for index := range world.Objects {
		if world.Objects[index].Kind == ObjectTreasure {
			treasure = &world.Objects[index]
			break
		}
	}
	if treasure == nil {
		t.Fatal("run omitted treasure")
	}
	world.Player.Pos = treasure.Pos
	world.Player.Grounded = false
	world.Step(InputFrame{})
	if world.Stats.Treasure != 1 {
		t.Fatalf("treasure was not collected: stats=%+v", world.Stats)
	}
	left, right := NewRunWorld(0x73), NewRunWorld(0x73)
	left.Stats.Treasure++
	if left.StateHash() == right.StateHash() {
		t.Fatal("state hash ignored future-visible run statistics")
	}
}

func TestRunReplayStaysDeterministic(t *testing.T) {
	world := NewRunWorld(99)
	replay := NewReplay(world.Seed)
	for tick := 0; tick < 180; tick++ {
		input := InputFrame{MoveX: 1}
		if tick == 8 || tick == 56 || tick == 124 {
			input.Jump = true
		}
		if tick == 92 {
			input.Roll = true
		}
		replay.Record(world, input)
	}
	played, err := replay.PlayRun()
	if err != nil {
		t.Fatalf("run replay diverged: %v", err)
	}
	if played.StateHash() != world.StateHash() {
		t.Fatalf("final hash mismatch: got %x want %x", played.StateHash(), world.StateHash())
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
