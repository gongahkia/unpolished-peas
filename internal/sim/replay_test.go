package sim

import "testing"

func replayWorld(seed uint64) *World {
	world := NewWorld(seed)
	world.SpawnEnemy(EnemyArcher, Vec{X: 500, Y: 160})
	world.SpawnEnemy(EnemyBrute, Vec{X: 180, Y: 220})
	return world
}

func TestReplayPlaybackMatchesRecordedHashes(t *testing.T) {
	world := replayWorld(77)
	replay := NewReplay(77)
	for _, input := range []InputFrame{
		{MoveX: 1, Attack: true, Staff: StaffLong}, {MoveX: 1}, {Dodge: true, MoveY: -1},
		{Clone: true}, {Transform: FormSparrow, MoveY: -1}, {}, {}, {},
	} {
		replay.Record(world, input)
	}
	if err := replay.Play(replayWorld(77)); err != nil {
		t.Fatalf("Play: %v", err)
	}
}

func TestReplayDetectsDivergence(t *testing.T) {
	world := replayWorld(88)
	replay := NewReplay(88)
	replay.Record(world, InputFrame{Attack: true})
	changed := replayWorld(88)
	changed.Player.HP--
	if err := replay.Play(changed); err == nil {
		t.Fatal("replay accepted a divergent initial state")
	}
}

func TestRunReplayRecreatesPilgrimageInputs(t *testing.T) {
	run := NewRun(123)
	replay := NewRunReplay(123)
	for _, frame := range []RunFrame{
		{Input: InputFrame{MoveX: 1, Attack: true, Staff: StaffLong}},
		{Input: InputFrame{MoveX: 1}},
		{Input: InputFrame{Dodge: true, MoveY: -1}},
		{Input: InputFrame{Clone: true}},
		{Input: InputFrame{Transform: FormSparrow, MoveY: -1}},
		{Input: InputFrame{}},
	} {
		if err := replay.Record(run, frame); err != nil {
			t.Fatalf("Record: %v", err)
		}
	}
	played, err := replay.Play()
	if err != nil {
		t.Fatalf("Play: %v", err)
	}
	if played.StateHash() != run.StateHash() {
		t.Fatalf("run replay final state mismatch: %x != %x", played.StateHash(), run.StateHash())
	}
}

func TestRunReplaySaveLoadAndPlayback(t *testing.T) {
	run := NewRun(124)
	replay := NewRunReplay(124)
	if err := replay.Record(run, RunFrame{Input: InputFrame{Attack: true, Staff: StaffShort}}); err != nil {
		t.Fatalf("Record: %v", err)
	}
	path := t.TempDir() + "/run.replay.json"
	if err := SaveRunReplay(path, replay); err != nil {
		t.Fatalf("SaveRunReplay: %v", err)
	}
	loaded, err := LoadRunReplay(path)
	if err != nil {
		t.Fatalf("LoadRunReplay: %v", err)
	}
	if _, err := loaded.Play(); err != nil {
		t.Fatalf("loaded replay did not play: %v", err)
	}
}
