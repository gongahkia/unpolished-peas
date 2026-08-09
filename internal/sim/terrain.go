package sim

type TerrainKind uint8

const (
	TerrainWall TerrainKind = iota
	TerrainPillar
	TerrainWater
	TerrainBreakable
	TerrainPlatform
)

type Rect struct{ X, Y, W, H float64 }

func (r Rect) contains(point Vec) bool {
	return point.X >= r.X && point.X <= r.X+r.W && point.Y >= r.Y && point.Y <= r.Y+r.H
}

func (r Rect) overlapsCircle(point Vec, radius float64) bool {
	x := clamp(point.X, r.X, r.X+r.W)
	y := clamp(point.Y, r.Y, r.Y+r.H)
	return Vec{X: x, Y: y}.Distance(point) < radius
}

type Terrain struct {
	ID     int
	Kind   TerrainKind
	Bounds Rect
	HP     int
}

func (t Terrain) solid() bool {
	return t.Kind == TerrainWall || t.Kind == TerrainPillar || (t.Kind == TerrainBreakable && t.HP > 0)
}

func (t Terrain) blocksProjectile() bool {
	// Landing platforms are permeable combat geometry. Full solids, rather
	// than every walkable surface, create readable cover and line breaks.
	return t.solid()
}

func validationTerrain() []Terrain {
	return []Terrain{
		// The stage starts with a safe training shelf, then forces a choice
		// between landing platforms, Bird flight, or a committed long-staff line.
		{ID: 1, Kind: TerrainWall, Bounds: Rect{X: 0, Y: 650, W: 280, H: 70}},
		{ID: 2, Kind: TerrainWater, Bounds: Rect{X: 280, Y: 650, W: 440, H: 70}},
		{ID: 3, Kind: TerrainWall, Bounds: Rect{X: 720, Y: 650, W: 560, H: 70}},
		{ID: 4, Kind: TerrainPlatform, Bounds: Rect{X: 70, Y: 530, W: 220, H: 20}},
		{ID: 5, Kind: TerrainPlatform, Bounds: Rect{X: 330, Y: 500, W: 180, H: 20}},
		{ID: 6, Kind: TerrainPlatform, Bounds: Rect{X: 545, Y: 420, W: 180, H: 20}},
		{ID: 7, Kind: TerrainBreakable, Bounds: Rect{X: 700, Y: 390, W: 34, H: 260}, HP: 2},
		{ID: 8, Kind: TerrainPlatform, Bounds: Rect{X: 760, Y: 510, W: 170, H: 20}},
		{ID: 9, Kind: TerrainPillar, Bounds: Rect{X: 875, Y: 430, W: 48, H: 80}},
		{ID: 10, Kind: TerrainPlatform, Bounds: Rect{X: 945, Y: 360, W: 250, H: 20}},
		{ID: 11, Kind: TerrainWall, Bounds: Rect{X: 1200, Y: 430, W: 28, H: 220}},
	}
}
