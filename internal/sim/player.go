package sim

type Action uint8

const (
	ActionIdle Action = iota
	ActionAttack
	ActionDodge
	ActionCounter
	ActionDead
)

func (a Action) String() string {
	switch a {
	case ActionAttack:
		return "attack"
	case ActionDodge:
		return "dodge"
	case ActionCounter:
		return "counter"
	case ActionDead:
		return "dead"
	default:
		return "idle"
	}
}

type AttackSpec struct {
	Startup, Active, Recovery int
	Range, Width              float64
	Damage                    int
	Knockback                 float64
}

func (a AttackSpec) Total() int { return a.Startup + a.Active + a.Recovery }

// Player is the complete mutable state for Wukong.
type Player struct {
	Pos, Velocity     Vec
	Facing            Vec
	HP, MaxHP         int
	Form              FormID
	Staff             StaffLength
	Action            Action
	ActionTick        int
	Combo             int
	AttackBuffer      int
	DodgeCooldown     int
	Invulnerable      int
	TransformCooldown int
	CloneCooldown     int
	Stagger           int
	CounterWindow     int
	LastAttackSpec    AttackSpec
	AttackHitIDs      map[int]bool
	Deaths            int
}

func newPlayer() Player {
	return Player{
		Pos:          Vec{X: ArenaW / 2, Y: ArenaH / 2},
		Facing:       Vec{X: 1},
		HP:           100,
		MaxHP:        100,
		Form:         FormMonkey,
		Staff:        StaffMedium,
		AttackHitIDs: make(map[int]bool),
	}
}

func (p *Player) radius() float64 { return rulesFor(p.Form).Radius }

func (p *Player) attackSpec() AttackSpec {
	rules := rulesFor(p.Form)
	if p.Form == FormTiger {
		return AttackSpec{Startup: 6, Active: 5, Recovery: 14, Range: 34, Width: 18, Damage: 20, Knockback: 7}
	}
	if p.Form == FormSparrow {
		return AttackSpec{Startup: 3, Active: 4, Recovery: 8, Range: 54, Width: 9, Damage: 7, Knockback: 3}
	}
	if p.Form == FormMantis {
		return AttackSpec{Startup: 2, Active: 5, Recovery: 10, Range: 38, Width: 10, Damage: 12, Knockback: 4}
	}
	if p.Form == FormCicada {
		return AttackSpec{Startup: 2, Active: 3, Recovery: 7, Range: 28, Width: 7, Damage: 6, Knockback: 2}
	}
	base := AttackSpec{Startup: 5, Active: 4, Recovery: 11, Range: 70, Width: 14, Damage: 13, Knockback: 5}
	switch p.Staff {
	case StaffShort:
		base = AttackSpec{Startup: 3, Active: 3, Recovery: 6, Range: 40, Width: 9, Damage: 9, Knockback: 3}
	case StaffLong:
		base = AttackSpec{Startup: 10, Active: 7, Recovery: 18, Range: 122, Width: 28, Damage: 20, Knockback: 9}
	}
	if p.Combo == 1 && p.Staff == StaffMedium {
		base.Damage = 15
		base.Range = 78
	}
	if p.Combo == 2 && p.Staff == StaffMedium {
		base.Damage = 19
		base.Range = 88
		base.Recovery = 15
	}
	base.Range *= rules.StaffScale
	base.Width *= rules.StaffScale
	base.Damage = int(float64(base.Damage)*rules.DamageMultiplier + 0.5)
	return base
}

func (p *Player) attackActive() bool {
	if p.Action != ActionAttack {
		return false
	}
	return p.ActionTick >= p.LastAttackSpec.Startup && p.ActionTick < p.LastAttackSpec.Startup+p.LastAttackSpec.Active
}

func (p *Player) attackRecovering() bool {
	return p.Action == ActionAttack && p.ActionTick >= p.LastAttackSpec.Startup+p.LastAttackSpec.Active
}
