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
