package sim

type Action uint8

const (
	ActionIdle Action = iota
	ActionShort
	ActionMedium
	ActionLongCharge
	ActionLongRelease
	ActionDodge
	ActionBirdDive
	ActionTigerPounce
	ActionMantisStance
	ActionDead
)

func (a Action) String() string {
	switch a {
	case ActionShort:
		return "short strike"
	case ActionMedium:
		return "medium combo"
	case ActionLongCharge:
		return "long extend"
	case ActionLongRelease:
		return "long release"
	case ActionDodge:
		return "cloud dodge"
	case ActionBirdDive:
		return "bird dive"
	case ActionTigerPounce:
		return "tiger pounce"
	case ActionMantisStance:
		return "mantis stance"
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
	Heavy                     bool
}

func (a AttackSpec) Total() int { return a.Startup + a.Active + a.Recovery }

type Player struct {
	Pos, Velocity     Vec
	Aim               Vec
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
	LongCharge        int
	LongRange         float64
	BirdMomentum      int
	Grounded          bool
	LastAttackSpec    AttackSpec
	AttackHitIDs      map[int]bool
	Deaths            int
}

func newPlayer() Player {
	return Player{Pos: Vec{X: ArenaW / 2, Y: ArenaH / 2}, Aim: Vec{X: 1}, HP: 120, MaxHP: 120, Form: FormMonkey, Staff: StaffMedium, AttackHitIDs: make(map[int]bool)}
}

func (p *Player) radius() float64 { return rulesFor(p.Form).Radius }

func shortSpec() AttackSpec {
	return AttackSpec{Startup: 2, Active: 3, Recovery: 4, Range: 34, Width: 8, Damage: 8, Knockback: 3}
}

func mediumSpec(combo int) AttackSpec {
	spec := AttackSpec{Startup: 5, Active: 5, Recovery: 10, Range: 64, Width: 22, Damage: 13, Knockback: 5}
	if combo == 1 {
		spec.Range, spec.Width, spec.Damage = 70, 28, 15
	}
	if combo >= 2 {
		spec.Startup, spec.Active, spec.Recovery = 7, 7, 15
		spec.Range, spec.Width, spec.Damage, spec.Knockback = 78, 34, 20, 8
		spec.Heavy = true
	}
	return spec
}

func (p *Player) actionActive() bool {
	return (p.Action == ActionShort || p.Action == ActionMedium || p.Action == ActionLongRelease) && p.ActionTick >= p.LastAttackSpec.Startup && p.ActionTick < p.LastAttackSpec.Startup+p.LastAttackSpec.Active
}
