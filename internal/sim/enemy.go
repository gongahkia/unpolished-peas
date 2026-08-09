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

type Enemy struct {
	ID             int
	Kind           EnemyKind
	Name           string
	Pos, Velocity  Vec
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
