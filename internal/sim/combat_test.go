package sim

import "testing"

func testEnemy(world *World, position Vec) *Enemy {
	enemy := &Enemy{
		ID:            world.nextEntityID(),
		Kind:          EnemyTarget,
		Name:          "target",
		Pos:           position,
		Radius:        10,
		HP:            200,
		MaxHP:         200,
		Damage:        12,
		MoveSpeed:     0,
		AttackRange:   0,
		TargetCloneID: -1,
	}
	world.Enemies = append(world.Enemies, enemy)
	return enemy
}

func step(world *World, input InputFrame, count int) {
	for range count {
		world.Step(input)
	}
}

func TestMovementAndAimAreIndependent(t *testing.T) {
	world := NewWorld(1)
	start := world.Player.Pos
	world.Step(InputFrame{MoveX: 1, AimY: -1})
	if world.Player.Pos.X <= start.X || world.Player.Pos.Y != start.Y {
		t.Fatalf("movement followed aim: start=%+v end=%+v", start, world.Player.Pos)
	}
	if world.Player.Aim != (Vec{Y: -1}) {
		t.Fatalf("aim did not retain independent arrow intent: %+v", world.Player.Aim)
	}
}

func TestStaffLengthsHaveDistinctTimingAndReach(t *testing.T) {
	if short, medium := shortSpec(), mediumSpec(0); short.Total() >= medium.Total() || short.Range >= medium.Range || short.Recovery >= medium.Recovery {
		t.Fatalf("short staff is not a fast close tool: short=%+v medium=%+v", short, medium)
	}

	mediumWorld := NewWorld(2)
	mediumTarget := testEnemy(mediumWorld, mediumWorld.Player.Pos.Add(Vec{X: 105}))
	mediumWorld.Step(InputFrame{Staff: StaffMedium, AimX: 1, Attack: true})
	step(mediumWorld, InputFrame{AimX: 1}, 24)
	if mediumTarget.HP != mediumTarget.MaxHP {
		t.Fatalf("medium staff reached target outside its sweep: hp=%d", mediumTarget.HP)
	}

	longWorld := NewWorld(2)
	longTarget := testEnemy(longWorld, longWorld.Player.Pos.Add(Vec{X: 105}))
	longWorld.Step(InputFrame{Staff: StaffLong, AimX: 1, Attack: true})
	step(longWorld, InputFrame{AimX: 1, Attack: true}, 30)
	longWorld.Step(InputFrame{AimX: 1})
	step(longWorld, InputFrame{AimX: 1}, 8)
	if longTarget.HP >= longTarget.MaxHP {
		t.Fatalf("charged long release did not reach its target: hp=%d", longTarget.HP)
	}
	if longWorld.Player.LastAttackSpec.Recovery <= mediumSpec(0).Recovery {
		t.Fatalf("long staff lacks committed recovery: long=%+v medium=%+v", longWorld.Player.LastAttackSpec, mediumSpec(0))
	}
}

func TestSnapshotExposesStaffPhaseAndChargeForecast(t *testing.T) {
	world := NewWorld(14)
	world.Step(InputFrame{Staff: StaffShort, AimX: 1, Attack: true})
	snapshot := world.Snapshot().Player
	if snapshot.Action != ActionShort || snapshot.AttackStartup != shortSpec().Startup || snapshot.AttackActive != shortSpec().Active || snapshot.AttackRecovery != shortSpec().Recovery {
		t.Fatalf("snapshot omitted short-staff phase information: %+v", snapshot)
	}

	world = NewWorld(15)
	world.Step(InputFrame{Staff: StaffLong, AimX: 1, Attack: true})
	snapshot = world.Snapshot().Player
	if snapshot.Action != ActionLongCharge || snapshot.LongCharge == 0 || snapshot.LongRange <= 28 {
		t.Fatalf("snapshot omitted long-staff charge forecast: %+v", snapshot)
	}
}

func TestMediumBuffersIntoItsNextSweep(t *testing.T) {
	world := NewWorld(10)
	world.Step(InputFrame{Staff: StaffMedium, AimX: 1, Attack: true})
	for world.Player.ActionTick < 14 {
		world.Step(InputFrame{AimX: 1})
	}
	world.Step(InputFrame{AimX: 1, Attack: true})
	for range 7 {
		world.Step(InputFrame{AimX: 1})
	}
	if world.Player.Action != ActionMedium || world.Player.Combo != 1 {
		t.Fatalf("medium recovery did not buffer its second sweep: action=%s combo=%d", world.Player.Action, world.Player.Combo)
	}
}

func TestMediumSweepClearsMultipleProjectiles(t *testing.T) {
	world := NewWorld(12)
	world.Projectiles = []*Projectile{
		{ID: 1, Pos: world.Player.Pos.Add(Vec{X: 38, Y: -12}), Radius: 5, TicksRemaining: 30, FromEnemy: true},
		{ID: 2, Pos: world.Player.Pos.Add(Vec{X: 42, Y: 12}), Radius: 5, TicksRemaining: 30, FromEnemy: true},
		{ID: 3, Pos: world.Player.Pos.Add(Vec{X: 42, Y: 45}), Radius: 5, TicksRemaining: 30, FromEnemy: true},
	}
	world.resolveAttack(world.Player.Pos, Vec{X: 1}, mediumSpec(0), map[int]bool{}, false, FormMonkey)
	if world.Projectiles[0].TicksRemaining != 0 || world.Projectiles[1].TicksRemaining != 0 {
		t.Fatal("medium sweep did not clear the close projectile fan")
	}
	if world.Projectiles[2].TicksRemaining == 0 {
		t.Fatal("medium sweep cleared a projectile outside its broad arc")
	}
}

func TestChargedLongCrossesWaterButNotSolidCover(t *testing.T) {
	world := NewWorld(11)
	world.Player.Pos = Vec{X: 100, Y: 180}
	world.Terrain = []Terrain{{ID: 1, Kind: TerrainWater, Bounds: Rect{X: 130, Y: 140, W: 80, H: 80}}}
	target := testEnemy(world, Vec{X: 224, Y: 180})
	world.Step(InputFrame{Staff: StaffLong, AimX: 1, Attack: true})
	step(world, InputFrame{AimX: 1, Attack: true}, 48)
	world.Step(InputFrame{AimX: 1})
	step(world, InputFrame{AimX: 1}, 8)
	if target.HP >= target.MaxHP {
		t.Fatal("charged long release did not strike across water")
	}

	blocked := NewWorld(11)
	blocked.Player.Pos = Vec{X: 100, Y: 180}
	blocked.Terrain = []Terrain{{ID: 1, Kind: TerrainPillar, Bounds: Rect{X: 165, Y: 140, W: 26, H: 80}}}
	blockedTarget := testEnemy(blocked, Vec{X: 224, Y: 180})
	blocked.Step(InputFrame{Staff: StaffLong, AimX: 1, Attack: true})
	step(blocked, InputFrame{AimX: 1, Attack: true}, 48)
	blocked.Step(InputFrame{AimX: 1})
	step(blocked, InputFrame{AimX: 1}, 8)
	if blockedTarget.HP != blockedTarget.MaxHP {
		t.Fatalf("solid pillar did not block long release: hp=%d", blockedTarget.HP)
	}
}

func TestBirdCrossesWaterAndCarriesExitMomentum(t *testing.T) {
	world := NewWorld(3)
	world.Terrain = []Terrain{{ID: 1, Kind: TerrainWater, Bounds: Rect{X: 205, Y: 142, W: 230, H: 58}}}
	world.Player.Pos = Vec{X: 193, Y: 170}
	world.Player.Form = FormMonkey
	start := world.Player.Pos
	world.Step(InputFrame{MoveX: 1})
	if world.Player.Pos != start {
		t.Fatalf("monkey crossed water: start=%+v end=%+v", start, world.Player.Pos)
	}
	world.Player.Form = FormBird
	world.Step(InputFrame{MoveX: 1})
	if world.Player.Pos.X <= start.X {
		t.Fatal("bird did not cross water")
	}
	world.Step(InputFrame{Transform: FormMonkey})
	if world.Player.BirdMomentum == 0 || world.Player.Velocity.LengthSq() == 0 {
		t.Fatalf("bird exit lost momentum: ticks=%d velocity=%+v", world.Player.BirdMomentum, world.Player.Velocity)
	}
}

func TestTigerPounceBreaksTerrainAndArmor(t *testing.T) {
	world := NewWorld(4)
	world.Terrain = []Terrain{{ID: 1, Kind: TerrainBreakable, Bounds: Rect{X: 398, Y: 205, W: 24, H: 70}, HP: 2}}
	world.Player.Form = FormTiger
	world.Player.Pos = Vec{X: 378, Y: 230}
	wall := &world.Terrain[0]
	world.Step(InputFrame{AimX: 1, Attack: true})
	step(world, InputFrame{AimX: 1}, 15)
	if wall.HP != 0 {
		t.Fatalf("tiger pounce did not destroy cracked wall: hp=%d", wall.HP)
	}

	world = NewWorld(5)
	world.Player.Form = FormTiger
	armored := testEnemy(world, world.Player.Pos.Add(Vec{X: 20}))
	armored.Armor = 30
	world.resolveAttack(world.Player.Pos, Vec{X: 1}, AttackSpec{Range: 30, Width: 10, Damage: 10, Knockback: 8, Heavy: true}, map[int]bool{}, false, FormTiger)
	if armored.Armor != 0 || armored.Stagger < 32 {
		t.Fatalf("tiger did not break armor: armor=%d stagger=%d", armored.Armor, armored.Stagger)
	}
}

func TestValidationWorldExceedsViewport(t *testing.T) {
	if ArenaW <= float64(ViewportW) || ArenaH <= float64(ViewportH) {
		t.Fatalf("validation world %0.fx%0.f does not exceed viewport %dx%d", ArenaW, ArenaH, ViewportW, ViewportH)
	}
	world := NewValidationWorld(16)
	if world.Player.Pos.Distance(world.Enemies[0].Pos) <= float64(ViewportW)/2 {
		t.Fatalf("validation encounter does not require travel: player=%+v boss=%+v", world.Player.Pos, world.Enemies[0].Pos)
	}
}

func TestMantisCounterCreatesWeakPoint(t *testing.T) {
	world := NewWorld(6)
	world.Player.Form = FormMantis
	enemy := testEnemy(world, world.Player.Pos.Add(Vec{X: 20}))
	enemy.Windup = 1
	world.Step(InputFrame{AimX: 1, Attack: true})
	if world.Player.Action != ActionMantisStance {
		t.Fatalf("mantis attack retained normal staff action: %s", world.Player.Action)
	}
	if enemy.Stagger < 72 || enemy.WeakPoint == 0 {
		t.Fatalf("mantis counter did not create a decisive state change: stagger=%d weak=%d", enemy.Stagger, enemy.WeakPoint)
	}
}

func TestEchoReplaysCapturedAttackFromItsSpawnPosition(t *testing.T) {
	world := NewWorld(7)
	for tick := 0; tick < 24; tick++ {
		input := InputFrame{AimX: 1}
		if tick == 5 {
			input.Attack = true
		}
		world.Step(input)
	}
	world.Step(InputFrame{AimX: 1, Clone: true})
	if len(world.Clones) != 1 {
		t.Fatal("echo did not spawn after a recorded window")
	}
	echo := world.Clones[0]
	spawn := echo.Pos
	step(world, InputFrame{}, 27)
	if echo.Action != ActionMedium {
		t.Fatalf("echo did not replay the captured staff press: action=%s index=%d", echo.Action, echo.EchoIndex)
	}
	if echo.Pos != spawn {
		t.Fatalf("echo moved without recorded movement: spawn=%+v current=%+v", spawn, echo.Pos)
	}
}

func TestBossGatesUseLongStaffThenEcho(t *testing.T) {
	world := NewValidationWorld(8)
	boss := world.Enemies[0]
	world.Step(InputFrame{})
	if !boss.Boss.Shielded || boss.Boss.EchoSeal {
		t.Fatalf("opening gate was not the long-staff gate: %+v", boss.Boss)
	}
	world.Player.Staff = StaffLong
	world.Player.Action = ActionLongRelease
	if !world.tryOpenBoss(boss, false) || boss.Boss.Shielded {
		t.Fatal("long release did not open opening shield")
	}

	boss.HP = boss.MaxHP / 2
	step(world, InputFrame{}, 16)
	if !boss.Boss.Shielded || !boss.Boss.EchoSeal {
		t.Fatalf("phase two did not create echo seal: %+v", boss.Boss)
	}
	if world.tryOpenBoss(boss, false) || !boss.Boss.Shielded {
		t.Fatal("player attack opened echo seal")
	}
	if !world.tryOpenBoss(boss, true) || boss.Boss.Shielded {
		t.Fatal("echo attack did not open echo seal")
	}
}

func TestValidationReplayIsDeterministic(t *testing.T) {
	world := NewValidationWorld(9)
	replay := NewReplay(world.Seed)
	for tick := 0; tick < 90; tick++ {
		input := InputFrame{AimX: 1}
		if tick < 30 {
			input.MoveY = -1
		}
		if tick == 10 {
			input.Attack, input.Staff = true, StaffShort
		}
		if tick >= 35 && tick < 64 {
			input.Attack, input.Staff = true, StaffLong
		}
		if tick == 70 {
			input.Clone = true
		}
		replay.Record(world, input)
	}
	played, err := replay.PlayValidation()
	if err != nil {
		t.Fatalf("replay diverged: %v", err)
	}
	if played.StateHash() != world.StateHash() {
		t.Fatalf("final hash mismatch: got %x want %x", played.StateHash(), world.StateHash())
	}
}

func TestStateHashIncludesFutureAffectingProjectileState(t *testing.T) {
	left, right := NewValidationWorld(13), NewValidationWorld(13)
	left.Projectiles = append(left.Projectiles, &Projectile{ID: 99, Pos: Vec{X: 200, Y: 180}, Velocity: Vec{X: 1}, Radius: 5, Damage: 9, TicksRemaining: 30, FromEnemy: true})
	right.Projectiles = append(right.Projectiles, &Projectile{ID: 99, Pos: Vec{X: 201, Y: 180}, Velocity: Vec{X: 1}, Radius: 5, Damage: 9, TicksRemaining: 30, FromEnemy: true})
	if left.StateHash() == right.StateHash() {
		t.Fatal("state hash ignored projectile state that could change a future encounter")
	}
}
