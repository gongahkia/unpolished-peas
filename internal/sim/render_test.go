package sim

import "testing"

func TestSnapshotIncludesEnemyMotionForVisualAnimation(t *testing.T) {
	w := World{Enemies: []Enemy{{Vel: Vec{X: 2.5, Y: -4}, Grounded: true}}}
	snapshot := w.Snapshot()
	if len(snapshot.Enemies) != 1 {
		t.Fatalf("enemy snapshot count = %d, want 1", len(snapshot.Enemies))
	}
	enemy := snapshot.Enemies[0]
	if enemy.Velocity != (Vec{X: 2.5, Y: -4}) {
		t.Fatalf("enemy velocity = %+v, want {X:2.5 Y:-4}", enemy.Velocity)
	}
	if !enemy.Grounded {
		t.Fatal("enemy grounded state was not copied into the render snapshot")
	}
}
