package sim

// Clone is a short-lived hair duplicate. Enemies can target it, and it repeats
// Wukong's attack after a short delay, making placement part of combat.
type Clone struct {
	ID              int
	Pos             Vec
	Facing          Vec
	Radius          float64
	TicksRemaining  int
	PendingAttack   int
	AttackSpec      AttackSpec
	HitIDs          map[int]bool
}
