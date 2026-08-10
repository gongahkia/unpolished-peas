package sim

import (
	"fmt"
	"path/filepath"
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
		seen := [3]bool{}
		for _, spawn := range layout.Spawns {
			seen[spawn.Archetype] = true
		}
		if !seen[EnemyCharger] || !seen[EnemyHopper] || !seen[EnemyDiver] {
			t.Fatalf("seed %d omitted an enemy archetype: %v", seed, seen)
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

func TestRunValidationRejectsUnsafePopulation(t *testing.T) {
	layout := GenerateRun(0x77)
	if len(layout.Spawns) == 0 {
		t.Fatal("test run omitted spawns")
	}
	spawn := &layout.Spawns[0]
	spawn.Pos = layout.Rooms[spawn.Room].Entry
	if issue := runValidationIssue(&layout); issue == "" {
		t.Fatal("validation accepted an enemy at a room entrance")
	}

	layout = GenerateRun(0x77)
	for index := range layout.Objects {
		if layout.Objects[index].Kind == ObjectDoor {
			layout.Objects[index].LinkID = 0
			if issue := runValidationIssue(&layout); issue == "" {
				t.Fatal("validation accepted an unlinked door")
			}
			return
		}
	}
	t.Fatal("test run omitted a linked door")
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

func TestRunReplayPersistsAndVerifiesFromDisk(t *testing.T) {
	world := NewRunWorld(0x75)
	replay := NewReplay(world.Seed)
	for tick := 0; tick < 90; tick++ {
		input := InputFrame{MoveX: 1, AimX: 1}
		if tick == 8 || tick == 46 {
			input.Jump = true
		}
		replay.Record(world, input)
	}
	path := filepath.Join(t.TempDir(), "run.replay.json")
	if err := SaveReplay(path, replay); err != nil {
		t.Fatalf("SaveReplay: %v", err)
	}
	loaded, err := LoadReplay(path)
	if err != nil {
		t.Fatalf("LoadReplay: %v", err)
	}
	played, err := loaded.PlayRun()
	if err != nil {
		t.Fatalf("saved run replay diverged: %v", err)
	}
	if played.StateHash() != world.StateHash() {
		t.Fatalf("loaded replay final hash mismatch: got %x want %x", played.StateHash(), world.StateHash())
	}
}

func TestStateHashCoversStoredAimAndEdgeInput(t *testing.T) {
	left, right := NewRunWorld(0x73), NewRunWorld(0x73)
	left.Player.Aim = Vec{X: -1}
	if left.StateHash() == right.StateHash() {
		t.Fatal("state hash ignored stored throw aim")
	}

	left, right = NewRunWorld(0x74), NewRunWorld(0x74)
	left.Hitstop, right.Hitstop = 1, 1
	left.Step(InputFrame{Throw: true})
	right.Step(InputFrame{})
	if left.StateHash() == right.StateHash() {
		t.Fatal("state hash ignored prior edge-trigger input during hitstop")
	}
}

func runFingerprint(layout RunLayout) string {
	fingerprint := layout.String()
	for _, room := range layout.Rooms {
		fingerprint += fmt.Sprintf("/r%d/%d/%d", room.Index, room.Template, room.ThreatBudget)
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

func q(value float64) int64 { return int64(value * 1000) }
