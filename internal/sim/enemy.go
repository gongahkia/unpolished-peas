package sim

type EnemyKind uint8

const (
	EnemyYaoguai EnemyKind = iota
	EnemyArcher
	EnemyBrute
	EnemyLancer
	EnemyHexer
	EnemyBoss
)

func (k EnemyKind) String() string {
	switch k {
	case EnemyArcher:
		return "archer"
	case EnemyBrute:
		return "brute"
	case EnemyLancer:
		return "lancer"
	case EnemyHexer:
		return "hexer"
	case EnemyBoss:
		return "boss"
	default:
		return "yaoguai"
	}
}

type Enemy struct {
	ID                 int
	Kind               EnemyKind
	Name               string
	Pos, Velocity      Vec
	Facing             Vec
	Radius             float64
	HP, MaxHP          int
	Damage             int
	MoveSpeed          float64
	AttackRange        float64
	AttackCooldown     int
	Windup             int
	Stagger            int
	Invulnerable       int
	TargetCloneID      int
	AIState            string
	Boss               *BossState
	LastDamagedByClone bool
}

func (e *Enemy) alive() bool { return e.HP > 0 }

func (e *Enemy) isBoss() bool { return e.Kind == EnemyBoss }
