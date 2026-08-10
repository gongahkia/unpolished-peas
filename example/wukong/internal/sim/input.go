package sim

// InputFrame is every deterministic player intent sampled for one tick of a
// procedural run. Aim is reserved for throws; it is not derived from movement.
type InputFrame struct {
	MoveX      int8
	AimX, AimY int8
	Jump       bool
	Down       bool
	Roll       bool
	Interact   bool
	Throw      bool
	DebugStep  bool
}
