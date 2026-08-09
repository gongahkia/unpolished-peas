package sim

import "testing"

func TestCompiledBossPatternTelegraphsAndAttacks(t *testing.T) {
	world := NewWorld(12)
	boss := world.SpawnBoss("yellow_wind_sage", "Yellow Wind Sage", Vec{X: 500, Y: 180}, 320)
	if boss.Boss.Program == nil || len(boss.Boss.Code) == 0 {
		t.Fatal("authored boss source was not compiled into runtime state")
	}
	world.Step(InputFrame{})
	if !boss.Boss.Shielded || boss.Boss.RequiredStaff != StaffLong {
		t.Fatalf("wind-wall telegraph was not executed: %+v", boss.Boss)
	}
	for range 55 {
		world.Step(InputFrame{})
	}
	if len(world.Projectiles) == 0 {
		t.Fatal("compiled attack command did not create projectiles")
	}
}

func TestBossPhaseConditionUsesCompiledSource(t *testing.T) {
	world := NewWorld(13)
	boss := world.SpawnBoss("golden_horn", "Golden Horn King", Vec{X: 500, Y: 180}, 390)
	boss.HP = 190
	world.Step(InputFrame{})
	if boss.Boss.PhaseName != "furnace" || boss.Boss.Phase != 1 {
		t.Fatalf("hp condition did not transition compiled phase: %+v", boss.Boss)
	}
}

func TestBossVulnerabilityRequirementsAreDistinct(t *testing.T) {
	world := NewWorld(14)
	yellow := world.SpawnBoss("yellow_wind_sage", "Yellow Wind Sage", Vec{X: 500, Y: 180}, 320)
	world.Step(InputFrame{})
	world.Player.Staff = StaffMedium
	world.tryOpenBoss(yellow, false)
	if !yellow.Boss.Shielded {
		t.Fatal("medium staff opened Yellow Wind's long-staff wall")
	}
	world.Player.Staff = StaffLong
	world.tryOpenBoss(yellow, false)
	if yellow.Boss.Shielded {
		t.Fatal("long staff did not open Yellow Wind's wall")
	}

	erlang := world.SpawnBoss("erlang_mirror", "Erlang's Mirror", Vec{X: 500, Y: 180}, 450)
	world.Step(InputFrame{})
	world.tryOpenBoss(erlang, false)
	if !erlang.Boss.Shielded {
		t.Fatal("non-clone strike opened Erlang's mirror")
	}
	world.tryOpenBoss(erlang, true)
	if erlang.Boss.Shielded {
		t.Fatal("clone strike did not open Erlang's mirror")
	}
}
