package sim

// InputFrame is every deterministic player intent sampled for one tick of the
// traversal lab. Aim is reserved for throws and the tether probe; it is not
// derived from movement.
type InputFrame struct {
	MoveX      int8
	AimX, AimY int8
	Jump       bool
	Down       bool
	Roll       bool
	Interact   bool
	Throw      bool
	Bomb       bool
	Rope       bool
	Tether     bool
	DebugStep  bool
}
