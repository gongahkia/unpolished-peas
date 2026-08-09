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
		{ID: 1, Kind: TerrainWater, Bounds: Rect{X: 300, Y: 210, W: 400, H: 180}},
		{ID: 2, Kind: TerrainPillar, Bounds: Rect{X: 490, Y: 84, W: 52, H: 92}},
		{ID: 3, Kind: TerrainPillar, Bounds: Rect{X: 875, Y: 492, W: 52, H: 92}},
		{ID: 4, Kind: TerrainBreakable, Bounds: Rect{X: 700, Y: 305, W: 34, H: 112}, HP: 2},
		{ID: 5, Kind: TerrainWall, Bounds: Rect{X: 118, Y: 575, W: 190, H: 24}},
		{ID: 6, Kind: TerrainWall, Bounds: Rect{X: 770, Y: 142, W: 196, H: 24}},
		{ID: 7, Kind: TerrainPillar, Bounds: Rect{X: 900, Y: 212, W: 46, H: 78}},
	}
}
