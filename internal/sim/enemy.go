package sim

type EnemyKind uint8

const (
	EnemyTarget EnemyKind = iota
	EnemyBoss
)

func (k EnemyKind) String() string {
	switch k {
	case EnemyBoss:
		return "boss"
	default:
		return "target"
	}
}

// EnemyArchetype selects deterministic locomotion and combat rules. Bosses
// retain their authored state machine rather than participating in the room
// encounter director.
type EnemyArchetype uint8

const (
	EnemyArchetypeNone EnemyArchetype = iota
	EnemyStalker
	EnemyKite
	EnemyGuardian
)

func (a EnemyArchetype) String() string {
	switch a {
	case EnemyStalker:
		return "stalker"
	case EnemyKite:
		return "kite"
	case EnemyGuardian:
		return "guardian"
	default:
		return "none"
	}
}

type EnemyRules struct {
	Radius, MoveSpeed, AttackRange float64
	HP, Damage, Armor              int
}

func archetypeRules(archetype EnemyArchetype) EnemyRules {
	switch archetype {
	case EnemyKite:
		return EnemyRules{Radius: 8, MoveSpeed: 2.8, AttackRange: 30, HP: 36, Damage: 9}
	case EnemyGuardian:
		return EnemyRules{Radius: 16, MoveSpeed: 1.35, AttackRange: 34, HP: 90, Damage: 20, Armor: 8}
	default:
		return EnemyRules{Radius: 11, MoveSpeed: 2.15, AttackRange: 32, HP: 48, Damage: 12}
	}
}

type Enemy struct {
	ID             int
	Kind           EnemyKind
	Archetype      EnemyArchetype
	Room           int
	Name           string
	Pos, Velocity  Vec
	Grounded       bool
	Facing         Vec
	Radius         float64
	HP, MaxHP      int
	Armor          int
	Damage         int
	MoveSpeed      float64
	AttackRange    float64
	AttackCooldown int
	Windup         int
	Stagger        int
	WeakPoint      int
	Flash          int
	Invulnerable   int
	TargetCloneID  int
	AIState        string
	Boss           *BossState
}

func (e *Enemy) alive() bool { return e.HP > 0 }
