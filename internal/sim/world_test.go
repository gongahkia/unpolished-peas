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
