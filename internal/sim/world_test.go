package sim

import "testing"

func advance(world *World, input InputFrame, ticks int) {
	world.Step(input)
	for range ticks - 1 {
		world.Step(InputFrame{})
	}
}

func TestLongStaffReachesPastMediumStaff(t *testing.T) {
	medium := NewWorld(1)
	mediumEnemy := medium.SpawnEnemy(EnemyYaoguai, medium.Player.Pos.Add(Vec{X: 105}))
	medium.Player.Staff = StaffMedium
	advance(medium, InputFrame{Attack: true}, 24)
	if mediumEnemy.HP != mediumEnemy.MaxHP {
		t.Fatalf("medium staff hit distant enemy: hp=%d", mediumEnemy.HP)
	}

	long := NewWorld(1)
	longEnemy := long.SpawnEnemy(EnemyYaoguai, long.Player.Pos.Add(Vec{X: 105}))
	long.Player.Staff = StaffLong
	advance(long, InputFrame{Attack: true}, 40)
	if longEnemy.HP >= longEnemy.MaxHP {
		t.Fatalf("long staff did not hit distant enemy: hp=%d", longEnemy.HP)
	}
}

func TestDodgeIsInvulnerableDuringEnemyStrike(t *testing.T) {
	world := NewWorld(2)
	enemy := world.SpawnEnemy(EnemyYaoguai, world.Player.Pos.Add(Vec{X: 20}))
	enemy.Windup = 1
	before := world.Player.HP
	world.Step(InputFrame{Dodge: true, MoveX: -1})
	if world.Player.HP != before {
		t.Fatalf("dodge took damage during i-frames: got %d want %d", world.Player.HP, before)
	}
	if world.Player.Action != ActionDodge || world.Player.Invulnerable == 0 {
		t.Fatalf("dodge did not establish invulnerability: action=%s i-frames=%d", world.Player.Action, world.Player.Invulnerable)
	}
}

func TestMantisCounterStaggersAttacker(t *testing.T) {
	world := NewWorld(3)
	enemy := world.SpawnEnemy(EnemyYaoguai, world.Player.Pos.Add(Vec{X: 20}))
	enemy.Windup = 1
	world.Player.Form = FormMantis
	world.Step(InputFrame{Attack: true})
	if enemy.Stagger < 40 {
		t.Fatalf("mantis counter did not stagger enemy: %d", enemy.Stagger)
	}
	if enemy.HP >= enemy.MaxHP {
		t.Fatalf("mantis counter did not deal counter damage")
	}
}

func TestCloneRepeatsAttack(t *testing.T) {
	world := NewWorld(4)
	enemy := world.SpawnEnemy(EnemyYaoguai, world.Player.Pos.Add(Vec{X: 45}))
	world.Step(InputFrame{Clone: true})
	if len(world.Clones) != 1 {
		t.Fatalf("clone did not spawn")
	}
	world.Step(InputFrame{})
	world.Step(InputFrame{Attack: true})
	for range 20 {
		world.Step(InputFrame{})
	}
	if enemy.HP >= enemy.MaxHP {
		t.Fatalf("clone/player attack did not damage nearby enemy")
	}
	if world.Player.CloneCooldown == 0 {
		t.Fatalf("clone mechanic did not apply its cooldown")
	}
}

func TestAttackPressedLateInRecoveryBuffersNextStrike(t *testing.T) {
	world := NewWorld(41)
	world.Step(InputFrame{Attack: true})
	for world.Player.ActionTick < 14 {
		world.Step(InputFrame{})
	}
	world.Step(InputFrame{Attack: true})
	for range 7 {
		world.Step(InputFrame{})
	}
	if world.Player.Action != ActionAttack || world.Player.ActionTick > 2 {
		t.Fatalf("late recovery input was not buffered into another attack: action=%s tick=%d", world.Player.Action, world.Player.ActionTick)
	}
}

func TestCloneDrawsEnemyTargeting(t *testing.T) {
	world := NewWorld(42)
	enemy := world.SpawnEnemy(EnemyYaoguai, world.Player.Pos.Sub(Vec{X: 50}))
	world.Step(InputFrame{Clone: true})
	if enemy.TargetCloneID < 0 {
		t.Fatal("nearby clone did not draw enemy targeting")
	}
}

func TestSparrowIgnoresHazardsAndStatueCannotMove(t *testing.T) {
	world := NewWorld(5)
	world.Player.Form = FormSparrow
	before := world.Player.HP
	world.damagePlayer(25, Vec{}, true)
	if world.Player.HP != before {
		t.Fatalf("sparrow took hazard damage: got %d want %d", world.Player.HP, before)
	}
	world.Player.Form = FormStatue
	position := world.Player.Pos
	world.Step(InputFrame{MoveX: 1})
	if world.Player.Pos != position {
		t.Fatalf("statue moved from %+v to %+v", position, world.Player.Pos)
	}
}

func TestCicadaClearsNormalEnemyTargeting(t *testing.T) {
	world := NewWorld(6)
	enemy := world.SpawnEnemy(EnemyYaoguai, world.Player.Pos.Add(Vec{X: 50}))
	world.Player.Form = FormCicada
	world.Step(InputFrame{})
	if enemy.AIState != "searching" {
		t.Fatalf("cicada left enemy in %q rather than searching", enemy.AIState)
	}
	if enemy.Windup != 0 {
		t.Fatalf("cicada allowed enemy to start an attack: %d", enemy.Windup)
	}
}

func TestLancerAndHexerHaveDistinctAttackRules(t *testing.T) {
	world := NewWorld(43)
	lancer := world.SpawnEnemy(EnemyLancer, world.Player.Pos.Add(Vec{X: 50}))
	hexer := world.SpawnEnemy(EnemyHexer, world.Player.Pos.Add(Vec{X: 100, Y: 20}))
	lancerStart := lancer.Pos
	world.enemyAttack(lancer, world.Player.Pos, nil)
	if lancer.Pos == lancerStart {
		t.Fatal("lancer attack did not lunge")
	}
	world.enemyAttack(hexer, world.Player.Pos, nil)
	if len(world.Projectiles) != 3 {
		t.Fatalf("hexer produced %d projectiles, want 3", len(world.Projectiles))
	}
}

func TestTigerBreaksArmorAndGiantResistsKnockback(t *testing.T) {
	world := NewWorld(44)
	brute := world.SpawnEnemy(EnemyBrute, world.Player.Pos.Add(Vec{X: 25}))
	world.Player.Form = FormTiger
	world.resolveStaffAttack(world.Player.Pos, world.Player.Facing, world.Player.attackSpec(), make(map[int]bool), false)
	if brute.Armor != 0 || brute.Stagger < 20 {
		t.Fatalf("tiger did not break armor: armor=%d stagger=%d", brute.Armor, brute.Stagger)
	}
	world.Player.Form = FormGiant
	world.damagePlayer(10, Vec{X: 10}, false)
	if world.Player.Velocity.X != 3.5 || world.Player.Stagger != 4 {
		t.Fatalf("giant knockback resistance incorrect: velocity=%+v stagger=%d", world.Player.Velocity, world.Player.Stagger)
	}
}

func TestShortStaffDeflectsMeleeStrike(t *testing.T) {
	world := NewWorld(45)
	enemy := world.SpawnEnemy(EnemyYaoguai, world.Player.Pos.Add(Vec{X: 20}))
	world.Player.Staff = StaffShort
	world.Player.Action = ActionAttack
	world.Player.ActionTick = world.Player.attackSpec().Startup
	world.Player.LastAttackSpec = world.Player.attackSpec()
	before := world.Player.HP
	world.enemyAttack(enemy, world.Player.Pos, nil)
	if world.Player.HP != before || enemy.Stagger < 20 {
		t.Fatalf("short-staff deflect failed: hp=%d stagger=%d", world.Player.HP, enemy.Stagger)
	}
}

func TestSameSeedAndInputFramesProduceSameState(t *testing.T) {
	left, right := NewWorld(99), NewWorld(99)
	for _, world := range []*World{left, right} {
		world.SpawnEnemy(EnemyArcher, Vec{X: 490, Y: 180})
		world.SpawnEnemy(EnemyBrute, Vec{X: 180, Y: 120})
	}
	frames := []InputFrame{
		{MoveX: 1, Attack: true, Staff: StaffLong},
		{MoveX: 1}, {MoveY: -1}, {Dodge: true, MoveY: -1}, {Clone: true},
		{Transform: FormSparrow, MoveX: -1}, {MoveX: -1}, {Transform: FormMonkey},
	}
	for _, frame := range frames {
		left.Step(frame)
		right.Step(frame)
	}
	for range 80 {
		left.Step(InputFrame{})
		right.Step(InputFrame{})
	}
	if left.StateHash() != right.StateHash() {
		t.Fatalf("deterministic simulations diverged: %x != %x", left.StateHash(), right.StateHash())
	}
}
