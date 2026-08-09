package sim

const (
	playerHalfW        = 8.0
	playerStandHalfH   = 11.0
	playerCrouchHalfH  = 7.0
	moveAcceleration   = 0.72
	moveTopSpeed       = 4.4
	jumpVelocity       = 10.4
	doubleJumpVelocity = 9.8
	coyoteTicks        = 7
	jumpBufferTicks    = 7
)

type TraversalState uint8

const (
	TraversalGrounded TraversalState = iota
	TraversalAirborne
	TraversalWallCling
	TraversalRolling
	TraversalClimbing
	TraversalDiving
	TraversalMantling
)

func (s TraversalState) String() string {
	switch s {
	case TraversalWallCling:
		return "wall cling"
	case TraversalRolling:
		return "roll"
	case TraversalClimbing:
		return "climb"
	case TraversalDiving:
		return "dive"
	case TraversalMantling:
		return "mantle"
	case TraversalAirborne:
		return "air"
	default:
		return "ground"
	}
}

type TetherState struct {
	Active bool
	Pos    Vec
}

type Player struct {
	Pos, Velocity Vec
	Aim           Vec
	Facing        int8
	Grounded      bool
	State         TraversalState
	Coyote        int
	JumpBuffer    int
	AirJumps      int
	WallDirection int8
	RollTicks     int
	RollCooldown  int
	Crouching     bool
	DropTicks     int
	MantleTicks   int
	ClimbObjectID int
	HeldObjectID  int
	Bombs         int
	Ropes         int
	Tether        TetherState
}

func newPlayer() Player {
	return Player{Aim: Vec{X: 1}, Facing: 1, AirJumps: 1, HeldObjectID: -1, ClimbObjectID: -1, Bombs: 3, Ropes: 3}
}

func (p Player) halfHeight() float64 {
	if p.RollTicks > 0 || p.DropTicks > 0 || p.Crouching {
		return playerCrouchHalfH
	}
	return playerStandHalfH
}

func (p Player) boundsAt(pos Vec) Rect {
	h := p.halfHeight()
	return Rect{X: pos.X - playerHalfW, Y: pos.Y - h, W: playerHalfW * 2, H: h * 2}
}
