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
