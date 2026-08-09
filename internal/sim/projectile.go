package sim

type Projectile struct {
	ID             int
	Pos, Velocity  Vec
	Radius         float64
	Damage         int
	TicksRemaining int
	FromEnemy      bool
	Hazard         bool
}

type EffectKind uint8

const (
	EffectImpact EffectKind = iota
	EffectTelegraph
	EffectStaffTrail
	EffectTransform
	EffectDeath
	EffectCounter
)

type Effect struct {
	Kind           EffectKind
	Pos, Direction Vec
	Radius         float64
	TicksRemaining int
}
