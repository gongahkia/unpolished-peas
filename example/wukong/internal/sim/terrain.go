package sim

type TerrainKind uint8

const (
	TerrainSolid TerrainKind = iota
	TerrainPlatform
	TerrainBreakable
	TerrainSpike
)

func (k TerrainKind) String() string {
	switch k {
	case TerrainPlatform:
		return "platform"
	case TerrainBreakable:
		return "breakable"
	case TerrainSpike:
		return "spike"
	default:
		return "solid"
	}
}

type Rect struct{ X, Y, W, H float64 }

func (r Rect) contains(point Vec) bool {
	return point.X >= r.X && point.X <= r.X+r.W && point.Y >= r.Y && point.Y <= r.Y+r.H
}

func (r Rect) overlaps(other Rect) bool {
	return r.X < other.X+other.W && r.X+r.W > other.X && r.Y < other.Y+other.H && r.Y+r.H > other.Y
}

func (r Rect) center() Vec { return Vec{X: r.X + r.W/2, Y: r.Y + r.H/2} }

type Terrain struct {
	ID     int
	Kind   TerrainKind
	Bounds Rect
	HP     int
}

func (t Terrain) solid() bool {
	return t.Kind == TerrainSolid || (t.Kind == TerrainBreakable && t.HP > 0)
}
