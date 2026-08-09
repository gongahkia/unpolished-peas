package sim

import "testing"

func testPlatformWorld(seed uint64) *World {
	w := NewWorld(seed)
	w.Terrain = []Terrain{{ID: 1, Kind: TerrainWall, Bounds: Rect{X: 0, Y: 500, W: ArenaW, H: 220}}}
	w.Player.Pos = Vec{X: 120, Y: 491}
	w.Player.Grounded = true
	return w
}

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
		Grounded:      true,
	}
	world.Enemies = append(world.Enemies, enemy)
	return enemy
}

func step(world *World, input InputFrame, count int) {
	for range count {
		world.Step(input)
	}
}

func TestPlatformMovementAndAimAreIndependent(t *testing.T) {
	world := testPlatformWorld(1)
	start := world.Player.Pos
	world.Step(InputFrame{MoveX: 1, AimY: -1})
	if world.Player.Pos.X <= start.X || world.Player.Pos.Y != start.Y {
		t.Fatalf("horizontal movement did not remain on the platform: start=%+v end=%+v", start, world.Player.Pos)
	}
	if world.Player.Aim != (Vec{Y: -1}) {
		t.Fatalf("aim did not retain independent arrow intent: %+v", world.Player.Aim)
	}
}

func TestPlatformLandingAndJump(t *testing.T) {
	world := testPlatformWorld(2)
	world.Player.Pos = Vec{X: 120, Y: 420}
	world.Player.Grounded = false
	step(world, InputFrame{}, 20)
	if !world.Player.Grounded || world.Player.Pos.Y != 491 {
		t.Fatalf("player did not land on the floor: pos=%+v grounded=%t", world.Player.Pos, world.Player.Grounded)
	}
	world.Step(InputFrame{Jump: true})
	if world.Player.Grounded || world.Player.Pos.Y >= 491 || world.Player.Velocity.Y >= 0 {
		t.Fatalf("jump did not launch an airborne player: pos=%+v velocity=%+v grounded=%t", world.Player.Pos, world.Player.Velocity, world.Player.Grounded)
	}
}

func TestOneWayPlatformCatchesBodiesWithoutBlockingCombatLines(t *testing.T) {
	world := NewWorld(22)
	world.Terrain = []Terrain{
		{ID: 1, Kind: TerrainWall, Bounds: Rect{X: 0, Y: 650, W: ArenaW, H: 70}},
		{ID: 2, Kind: TerrainPlatform, Bounds: Rect{X: 80, Y: 500, W: 220, H: 20}},
	}
	world.Player.Pos = Vec{X: 140, Y: 400}
	step(world, InputFrame{}, 20)
	if !world.Player.Grounded || world.Player.Pos.Y != 491 {
		t.Fatalf("one-way platform did not catch falling player: pos=%+v grounded=%t", world.Player.Pos, world.Player.Grounded)
	}
	if blocked, _ := world.firstProjectileBlock(Vec{X: 90, Y: 510}, Vec{X: 290, Y: 510}); blocked {
		t.Fatal("one-way platform incorrectly blocked a combat line")
	}
}

func TestStaffLengthsHaveDistinctTimingAndReach(t *testing.T) {
	if short, medium := shortSpec(), mediumSpec(0); short.Total() >= medium.Total() || short.Range >= medium.Range || short.Recovery >= medium.Recovery {
		t.Fatalf("short staff is not a fast close tool: short=%+v medium=%+v", short, medium)
	}

	shortWorld := testPlatformWorld(3)
	shortTarget := testEnemy(shortWorld, Vec{X: 148, Y: 490})
	shortWorld.Step(InputFrame{Staff: StaffShort, AimX: 1, Attack: true})
	step(shortWorld, InputFrame{AimX: 1}, 5)
	if shortTarget.HP >= shortTarget.MaxHP {
		t.Fatal("short staff missed an adjacent target")
	}

	mediumWorld := testPlatformWorld(4)
	mediumTarget := testEnemy(mediumWorld, Vec{X: 180, Y: 490})
	mediumWorld.Step(InputFrame{Staff: StaffMedium, AimX: 1, Attack: true})
	step(mediumWorld, InputFrame{AimX: 1}, 16)
	if mediumTarget.HP >= mediumTarget.MaxHP {
		t.Fatal("medium staff did not reach its conventional sweep range")
	}

	longWorld := testPlatformWorld(5)
	longTarget := testEnemy(longWorld, Vec{X: 250, Y: 490})
	longWorld.Step(InputFrame{Staff: StaffLong, AimX: 1, Attack: true})
	step(longWorld, InputFrame{AimX: 1, Attack: true}, 48)
	longWorld.Step(InputFrame{AimX: 1})
	step(longWorld, InputFrame{AimX: 1}, 8)
	if longTarget.HP >= longTarget.MaxHP {
		t.Fatalf("charged long release did not reach distant target: hp=%d", longTarget.HP)
	}
	if longWorld.Player.LastAttackSpec.Recovery <= mediumSpec(0).Recovery {
		t.Fatalf("long staff lacks committed recovery: long=%+v medium=%+v", longWorld.Player.LastAttackSpec, mediumSpec(0))
	}
}

func TestSnapshotExposesStaffPhaseAndChargeForecast(t *testing.T) {
	world := testPlatformWorld(6)
	world.Step(InputFrame{Staff: StaffShort, AimX: 1, Attack: true})
	snapshot := world.Snapshot().Player
	if snapshot.Action != ActionShort || snapshot.AttackStartup != shortSpec().Startup || snapshot.AttackActive != shortSpec().Active || snapshot.AttackRecovery != shortSpec().Recovery {
		t.Fatalf("snapshot omitted short-staff phase information: %+v", snapshot)
	}

	world = testPlatformWorld(7)
	world.Step(InputFrame{Staff: StaffLong, AimX: 1, Attack: true})
	snapshot = world.Snapshot().Player
	if snapshot.Action != ActionLongCharge || snapshot.LongCharge == 0 || snapshot.LongRange <= 28 {
		t.Fatalf("snapshot omitted long-staff charge forecast: %+v", snapshot)
	}
}

func TestMediumBuffersIntoItsNextSweep(t *testing.T) {
	world := testPlatformWorld(8)
	world.Step(InputFrame{Staff: StaffMedium, AimX: 1, Attack: true})
	for world.Player.ActionTick < 14 {
		world.Step(InputFrame{AimX: 1})
	}
	world.Step(InputFrame{AimX: 1, Attack: true})
	step(world, InputFrame{AimX: 1}, 7)
	if world.Player.Action != ActionMedium || world.Player.Combo != 1 {
		t.Fatalf("medium recovery did not buffer its second sweep: action=%s combo=%d", world.Player.Action, world.Player.Combo)
	}
}

func TestLongCrossesWaterButNotSolidCover(t *testing.T) {
	world := testPlatformWorld(9)
	world.Terrain = append(world.Terrain, Terrain{ID: 2, Kind: TerrainWater, Bounds: Rect{X: 175, Y: 430, W: 80, H: 70}})
	target := testEnemy(world, Vec{X: 275, Y: 490})
	world.resolveAttack(world.Player.Pos, Vec{X: 1}, AttackSpec{Range: 180, Width: 12, Damage: 20}, map[int]bool{}, false, FormMonkey)
	if target.HP >= target.MaxHP {
		t.Fatal("staff strike did not cross a water hazard")
	}

	blocked := testPlatformWorld(10)
	blocked.Terrain = append(blocked.Terrain, Terrain{ID: 2, Kind: TerrainPillar, Bounds: Rect{X: 180, Y: 420, W: 28, H: 80}})
	blockedTarget := testEnemy(blocked, Vec{X: 275, Y: 490})
	blocked.resolveAttack(blocked.Player.Pos, Vec{X: 1}, AttackSpec{Range: 180, Width: 12, Damage: 20}, map[int]bool{}, false, FormMonkey)
	if blockedTarget.HP != blockedTarget.MaxHP {
		t.Fatalf("solid pillar did not block long reach: hp=%d", blockedTarget.HP)
	}
}

func TestBirdIgnoresWaterAndCarriesExitMomentum(t *testing.T) {
	monkey := testPlatformWorld(11)
	monkey.Terrain = []Terrain{
		{ID: 1, Kind: TerrainWall, Bounds: Rect{X: 0, Y: 500, W: 180, H: 220}},
		{ID: 2, Kind: TerrainWater, Bounds: Rect{X: 180, Y: 500, W: 120, H: 220}},
		{ID: 3, Kind: TerrainWall, Bounds: Rect{X: 300, Y: 500, W: ArenaW - 300, H: 220}},
	}
	monkey.Player.Pos = Vec{X: 174, Y: 491}
	monkey.Player.Grounded = true
	startHP := monkey.Player.HP
	step(monkey, InputFrame{MoveX: 1}, 4)
	if monkey.Player.HP >= startHP {
		t.Fatal("water did not punish the normal form")
	}

	bird := testPlatformWorld(12)
	bird.Terrain = monkey.Terrain
	bird.Player.Pos = Vec{X: 174, Y: 491}
	bird.Player.Grounded = true
	bird.Player.Form = FormBird
	birdHP := bird.Player.HP
	bird.Step(InputFrame{MoveX: 1, Jump: true})
	step(bird, InputFrame{MoveX: 1}, 4)
	if bird.Player.HP != birdHP || bird.Player.Pos.X <= 174 {
		t.Fatalf("bird did not safely fly across water: hp=%d pos=%+v", bird.Player.HP, bird.Player.Pos)
	}
	bird.Step(InputFrame{Transform: FormMonkey})
	if bird.Player.BirdMomentum == 0 || bird.Player.Velocity.X == 0 {
		t.Fatalf("bird exit lost momentum: ticks=%d velocity=%+v", bird.Player.BirdMomentum, bird.Player.Velocity)
	}
}

func TestTigerPounceBreaksTerrainAndArmor(t *testing.T) {
	world := testPlatformWorld(13)
	world.Terrain = append(world.Terrain, Terrain{ID: 2, Kind: TerrainBreakable, Bounds: Rect{X: 170, Y: 430, W: 24, H: 70}, HP: 2})
	world.Player.Form = FormTiger
	world.Player.Pos = Vec{X: 145, Y: 488}
	wall := &world.Terrain[1]
	world.Step(InputFrame{AimX: 1, Attack: true})
	step(world, InputFrame{AimX: 1}, 15)
	if wall.HP != 0 {
		t.Fatalf("tiger pounce did not destroy cracked wall: hp=%d", wall.HP)
	}

	world = testPlatformWorld(14)
	armored := testEnemy(world, Vec{X: 145, Y: 490})
	armored.Armor = 30
	world.resolveAttack(world.Player.Pos, Vec{X: 1}, AttackSpec{Range: 30, Width: 10, Damage: 10, Knockback: 8, Heavy: true}, map[int]bool{}, false, FormTiger)
	if armored.Armor != 0 || armored.Stagger < 32 {
		t.Fatalf("tiger did not break armor: armor=%d stagger=%d", armored.Armor, armored.Stagger)
	}
}

func TestMantisCounterCreatesWeakPoint(t *testing.T) {
	world := testPlatformWorld(15)
	world.Player.Form = FormMantis
	enemy := testEnemy(world, Vec{X: 140, Y: 490})
	enemy.Windup = 1
	world.Step(InputFrame{AimX: 1, Attack: true})
	if world.Player.Action != ActionMantisStance {
		t.Fatalf("mantis attack retained normal staff action: %s", world.Player.Action)
	}
	if enemy.Stagger < 72 || enemy.WeakPoint == 0 {
		t.Fatalf("mantis counter did not create a decisive state change: stagger=%d weak=%d", enemy.Stagger, enemy.WeakPoint)
	}
}

func TestEchoReplaysAttackFromItsSpawnPlatform(t *testing.T) {
	world := testPlatformWorld(16)
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
	if echo.Pos.X != spawn.X || !echo.Grounded {
		t.Fatalf("echo did not retain its spawn-platform replay position: spawn=%+v current=%+v grounded=%t", spawn, echo.Pos, echo.Grounded)
	}
}

func TestValidationStageUsesPlatformsAndExceedsViewport(t *testing.T) {
	if ArenaW <= float64(ViewportW) || ArenaH <= float64(ViewportH) {
		t.Fatalf("validation world %0.fx%0.f does not exceed viewport %dx%d", ArenaW, ArenaH, ViewportW, ViewportH)
	}
	world := NewValidationWorld(17)
	hasPlatform, hasWater, hasCrackedWall := false, false, false
	for _, terrain := range world.Terrain {
		hasPlatform = hasPlatform || terrain.Kind == TerrainPlatform
		hasWater = hasWater || terrain.Kind == TerrainWater
		hasCrackedWall = hasCrackedWall || terrain.Kind == TerrainBreakable
	}
	if !hasPlatform || !hasWater || !hasCrackedWall || world.Player.Pos.Distance(world.Enemies[0].Pos) <= float64(ViewportW)/2 {
		t.Fatalf("validation stage is not a scrolling platform encounter: terrain=%+v player=%+v boss=%+v", world.Terrain, world.Player.Pos, world.Enemies[0].Pos)
	}
}

func TestValidationStageHasAMonkeyClimbToWardenPlatform(t *testing.T) {
	world := NewValidationWorld(23)
	world.Enemies = nil // isolate authored traversal from Warden's combat loop.

	// The player can run from the east landing shelf onto the pillar top.
	world.Player.Pos = Vec{X: 828, Y: 501}
	world.Player.Grounded = true
	world.Step(InputFrame{MoveX: 1, Jump: true})
	step(world, InputFrame{MoveX: 1}, 20)
	step(world, InputFrame{}, 5)
	if !world.Player.Grounded || world.Player.Pos.Y != 421 || world.Player.Pos.X <= 875 {
		t.Fatalf("monkey could not clear the pillar step: pos=%+v grounded=%t", world.Player.Pos, world.Player.Grounded)
	}

	// From the pillar top, the raised Warden platform is one normal jump away.
	world.Player.Pos = Vec{X: 900, Y: 421}
	world.Player.Grounded = true
	world.Step(InputFrame{MoveX: 1, Jump: true})
	step(world, InputFrame{MoveX: 1}, 16)
	step(world, InputFrame{}, 8)
	if !world.Player.Grounded || world.Player.Pos.Y != 351 || world.Player.Pos.X < 945 {
		t.Fatalf("monkey could not reach Warden's platform: pos=%+v grounded=%t", world.Player.Pos, world.Player.Grounded)
	}
}

func TestBossGatesUseLongStaffThenEcho(t *testing.T) {
	world := NewValidationWorld(18)
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

func TestBossSweepUsesTheSameCounterRules(t *testing.T) {
	world := testPlatformWorld(21)
	boss := world.SpawnArenaBoss(Vec{X: 180, Y: 479})
	world.Player.Form = FormMantis
	world.Player.Action = ActionMantisStance
	world.Player.CounterWindow = 10
	before := world.Player.HP
	world.bossSweep(boss)
	if world.Player.HP != before || boss.WeakPoint == 0 || boss.Stagger < 72 {
		t.Fatalf("boss sweep bypassed mantis counter: hp=%d weak=%d stagger=%d", world.Player.HP, boss.WeakPoint, boss.Stagger)
	}
}

func TestValidationReplayIsDeterministic(t *testing.T) {
	world := NewValidationWorld(19)
	replay := NewReplay(world.Seed)
	for tick := 0; tick < 90; tick++ {
		input := InputFrame{AimX: 1}
		if tick < 30 {
			input.MoveX = 1
		}
		if tick == 8 || tick == 43 {
			input.Jump = true
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

func TestStateHashIncludesFutureAffectingPlatformState(t *testing.T) {
	left, right := NewValidationWorld(20), NewValidationWorld(20)
	left.Player.Grounded = true
	right.Player.Grounded = false
	if left.StateHash() == right.StateHash() {
		t.Fatal("state hash ignored grounded state that changes future jump behavior")
	}
}
