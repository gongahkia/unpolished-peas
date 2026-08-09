package sim

// Clone is a deterministic Echo. It replays the preceding input window from
// its spawn point after a readable countdown; it has no autonomous combat AI.
type Clone struct {
	ID               int
	Pos, Aim         Vec
	Radius           float64
	Form             FormID
	Velocity         Vec
	Delay, EchoIndex int
	Frames           []InputFrame
	Previous         InputFrame
	Staff            StaffLength
	Action           Action
	ActionTick       int
	LongCharge       int
	LongRange        float64
	AttackSpec       AttackSpec
	HitIDs           map[int]bool
	TicksRemaining   int
}
