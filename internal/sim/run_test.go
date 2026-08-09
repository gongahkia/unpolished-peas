package sim

import "testing"

func TestPilgrimageRouteContainsThreeDistinctBosses(t *testing.T) {
	run := NewRun(44)
	seen := make(map[string]bool)
	for _, node := range run.Nodes {
		if node.Kind == EncounterBoss {
			seen[node.ID] = true
		}
	}
	for _, id := range []string{"yellow", "golden", "erlang"} {
		if !seen[id] {
			t.Fatalf("route missing boss node %q", id)
		}
	}
}

func TestRunRequiresClearBeforeAdvanceAndPreservesVow(t *testing.T) {
	run := NewRun(8)
	if err := run.Advance(0); err == nil {
		t.Fatal("advanced without clearing an encounter")
	}
	run.World.Won = true
	if err := run.Advance(0); err != nil {
		t.Fatalf("advance after clear: %v", err)
	}
	// Move to the shrine node selected by this branch.
	run.World.Won = true
	if err := run.Advance(0); err != nil {
		t.Fatalf("advance to shrine: %v", err)
	}
	if run.CurrentNode().Kind != EncounterShrine {
		t.Fatalf("expected shrine, got %s", run.CurrentNode().Kind)
	}
	if err := run.ChooseVow(VowSilence); err != nil {
		t.Fatalf("ChooseVow: %v", err)
	}
	if !run.World.Vows[VowSilence] {
		t.Fatal("vow not carried by world")
	}
}

func TestRestartCurrentRetainsRunChoicesAndRebuildsEncounter(t *testing.T) {
	run := NewRun(9)
	run.World.Vows[VowCloudbound] = true
	run.Vows = append(run.Vows, VowCloudbound)
	run.World.Player.HP = 1
	run.World.Lost = true
	run.RestartCurrent()
	if run.World.Player.HP != run.World.Player.MaxHP {
		t.Fatalf("restart left player at %d hp", run.World.Player.HP)
	}
	if !run.World.Vows[VowCloudbound] {
		t.Fatal("restart discarded selected vow")
	}
	if len(run.World.Enemies) == 0 {
		t.Fatal("restart did not rebuild the current encounter")
	}
}

func TestCompanionRulesChangeCombatBehavior(t *testing.T) {
	bajie := NewWorld(10)
	bajie.Companion = CompanionBajie
	bajie.SpawnClone()
	if len(bajie.Clones) != 2 {
		t.Fatalf("Bajie spawned %d clones, want 2", len(bajie.Clones))
	}
	wujing := NewWorld(11)
	wujing.Companion = CompanionWujing
	wujing.Projectiles = append(wujing.Projectiles, &Projectile{Pos: wujing.Player.Pos.Add(Vec{X: 20}), Radius: 5, FromEnemy: true})
	wujing.startDodge(InputFrame{MoveX: 1})
	if len(wujing.Projectiles) != 0 {
		t.Fatal("Wujing cloud dodge did not clear nearby projectile")
	}
}
