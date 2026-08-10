package sim

type ObjectKind uint8

const (
	ObjectCrate ObjectKind = iota
	ObjectRock
	ObjectPlate
	ObjectDoor
	ObjectExit
	ObjectTreasure
)

func (k ObjectKind) String() string {
	switch k {
	case ObjectCrate:
		return "crate"
	case ObjectRock:
		return "rock"
	case ObjectPlate:
		return "plate"
	case ObjectDoor:
		return "door"
	case ObjectExit:
		return "exit"
	case ObjectTreasure:
		return "treasure"
	default:
		return "unknown"
	}
}

// WorldObject is deterministic physical, linked, collectible, or exit state.
// Positions are centers; Size defines the collision bounds.
type WorldObject struct {
	ID       int
	Kind     ObjectKind
	Pos, Vel Vec
	Size     Vec
	LinkID   int
	Active   bool
	Held     bool
}

func (o WorldObject) bounds() Rect {
	return Rect{X: o.Pos.X - o.Size.X/2, Y: o.Pos.Y - o.Size.Y/2, W: o.Size.X, H: o.Size.Y}
}

func (o WorldObject) movable() bool { return o.Kind == ObjectCrate || o.Kind == ObjectRock }
