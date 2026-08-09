package sim

type TerrainKind uint8

const (
	TerrainWall TerrainKind = iota
	TerrainPillar
	TerrainWater
	TerrainBreakable
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

func (t Terrain) blocks(form FormID) bool {
	return t.Kind == TerrainWall || t.Kind == TerrainPillar || (t.Kind == TerrainBreakable && t.HP > 0) || (t.Kind == TerrainWater && !rulesFor(form).CanCrossWater)
}

func (t Terrain) blocksProjectile() bool {
	return t.Kind != TerrainWater && (t.Kind != TerrainBreakable || t.HP > 0)
}

func validationTerrain() []Terrain {
	return []Terrain{
		{ID: 1, Kind: TerrainWater, Bounds: Rect{X: 205, Y: 142, W: 230, H: 58}},
		{ID: 2, Kind: TerrainPillar, Bounds: Rect{X: 290, Y: 72, W: 38, H: 62}},
		{ID: 3, Kind: TerrainPillar, Bounds: Rect{X: 454, Y: 230, W: 42, H: 68}},
		{ID: 4, Kind: TerrainBreakable, Bounds: Rect{X: 398, Y: 205, W: 24, H: 70}, HP: 2},
		{ID: 5, Kind: TerrainWall, Bounds: Rect{X: 88, Y: 245, W: 104, H: 22}},
	}
}
