package sim

import (
	"fmt"
	"math"
	"sort"
)

const GeneratorVersion = "72-run-1"

type RoomRole uint8

const (
	RoomEntry RoomRole = iota
	RoomTraversal
	RoomCombat
	RoomEscalation
	RoomFinale
)

func (r RoomRole) String() string {
	switch r {
	case RoomEntry:
		return "entry"
	case RoomTraversal:
		return "traversal"
	case RoomCombat:
		return "combat"
	case RoomEscalation:
		return "escalation"
	default:
		return "finale"
	}
}

// RoomInfo describes one generated section of a continuous run. Its anchors
// are part of the deterministic layout contract and are never renderer state.
type RoomInfo struct {
	Index         int
	Role          RoomRole
	Bounds        Rect
	Entry, Exit   Vec
	ThreatBudget  int
	Variant       int
	BirdShortcut  bool
	TigerShortcut bool
}

type NavNode struct {
	ID   int
	Room int
	Pos  Vec
}

type NavLink struct{ From, To int }

type EnemySpawn struct {
	Room      int
	Archetype EnemyArchetype
	Pos       Vec
	Cost      int
}

// RunLayout is generated once from its seed. World owns the mutable terrain
// health and activation state; this structure remains the reproducible plan.
type RunLayout struct {
	Seed       uint64
	Attempt    int
	Rooms      []RoomInfo
	Terrain    []Terrain
	Spawns     []EnemySpawn
	NavNodes   []NavNode
	NavLinks   []NavLink
	WardenPos  Vec
	Valid      bool
}

type layoutRNG struct{ state uint64 }

func newLayoutRNG(seed uint64) *layoutRNG {
	if seed == 0 {
		seed = 1
	}
	return &layoutRNG{state: seed}
}

func (r *layoutRNG) next() uint64 {
	r.state ^= r.state << 13
	r.state ^= r.state >> 7
	r.state ^= r.state << 17
	return r.state
}

func (r *layoutRNG) intn(limit int) int {
	if limit <= 1 {
		return 0
	}
	return int(r.next() % uint64(limit))
}

// GenerateRun creates a constrained, continuously connected five-room run.
// Every random choice is local to this generator and independent from combat RNG.
func GenerateRun(seed uint64) RunLayout {
	for attempt := 0; attempt < 8; attempt++ {
		layout := generateRunAttempt(seed, attempt)
		if validateRunLayout(&layout) {
			layout.Valid = true
			return layout
		}
	}
	layout := generateRunAttempt(1, 0)
	layout.Valid = validateRunLayout(&layout)
	return layout
}

func generateRunAttempt(seed uint64, attempt int) RunLayout {
	rng := newLayoutRNG(seed ^ uint64(attempt+1)*0x9e3779b97f4a7c15)
	layout := RunLayout{Seed: seed, Attempt: attempt}
	roles := []RoomRole{RoomEntry, RoomTraversal, RoomCombat, RoomEscalation, RoomFinale}
	nextTerrainID := 1
	for index, role := range roles {
		offset := float64(index) * RoomW
		room := RoomInfo{
			Index:         index,
			Role:          role,
			Bounds:        Rect{X: offset, Y: 0, W: RoomW, H: ArenaH},
			Entry:         Vec{X: offset + 48, Y: 641},
			Exit:          Vec{X: offset + RoomW - 48, Y: 641},
			ThreatBudget:  roomThreat(role),
			Variant:       rng.intn(3),
			BirdShortcut:  role != RoomFinale,
			TigerShortcut: role == RoomTraversal || role == RoomEscalation,
		}
		layout.Rooms = append(layout.Rooms, room)
		if role == RoomFinale {
			terrain, wardenPos := generateFinaleRoom(room, &nextTerrainID)
			layout.Terrain = append(layout.Terrain, terrain...)
			layout.WardenPos = wardenPos
			continue
		}
		terrain := generateRouteRoom(room, &nextTerrainID, rng)
		layout.Terrain = append(layout.Terrain, terrain...)
		layout.Spawns = append(layout.Spawns, roomSpawns(room)...)
	}
	layout.NavNodes, layout.NavLinks = buildNavigation(layout.Terrain, layout.Rooms)
	return layout
}

func roomThreat(role RoomRole) int {
	switch role {
	case RoomCombat:
		return 4
	case RoomEscalation:
		return 7
	default:
		return 0
	}
}

func addTerrain(nextID *int, kind TerrainKind, bounds Rect, hp int) Terrain {
	terrain := Terrain{ID: *nextID, Kind: kind, Bounds: bounds, HP: hp}
	*nextID++
	return terrain
}

func generateRouteRoom(room RoomInfo, nextID *int, rng *layoutRNG) []Terrain {
	offset := room.Bounds.X
	leftEnd, rightStart := 192.0, 384.0
	if room.Variant == 1 {
		leftEnd, rightStart = 208, 400
	}
	if room.Variant == 2 {
		leftEnd, rightStart = 176, 368
	}
	terrain := []Terrain{
		addTerrain(nextID, TerrainWall, Rect{X: offset, Y: 650, W: leftEnd, H: 70}, 0),
		addTerrain(nextID, TerrainWater, Rect{X: offset + leftEnd, Y: 650, W: rightStart - leftEnd, H: 70}, 0),
		addTerrain(nextID, TerrainWall, Rect{X: offset + rightStart, Y: 650, W: RoomW - rightStart, H: 70}, 0),
		// The two low platforms are the guaranteed Monkey route over water.
		addTerrain(nextID, TerrainPlatform, Rect{X: offset + leftEnd + 12, Y: 596, W: 88, H: 18}, 0),
		addTerrain(nextID, TerrainPlatform, Rect{X: offset + rightStart - 92, Y: 564, W: 100, H: 18}, 0),
		// High ledges supply Long lanes, Bird flight space, and Echo staging.
		addTerrain(nextID, TerrainPlatform, Rect{X: offset + 300, Y: 456 + float64(room.Variant)*16, W: 112, H: 18}, 0),
		addTerrain(nextID, TerrainPlatform, Rect{X: offset + 470, Y: 504 - float64(room.Variant)*14, W: 104, H: 18}, 0),
	}
	if room.Role == RoomTraversal || room.Role == RoomEscalation {
		terrain = append(terrain,
			addTerrain(nextID, TerrainBreakable, Rect{X: offset + 430, Y: 380, W: 34, H: 120}, 2),
			addTerrain(nextID, TerrainPillar, Rect{X: offset + 520, Y: 412, W: 42, H: 92}, 0),
		)
	}
	if room.Role == RoomCombat || room.Role == RoomEscalation {
		coverX := offset + 420 + float64(rng.intn(3))*32
		terrain = append(terrain, addTerrain(nextID, TerrainPillar, Rect{X: coverX, Y: 490, W: 38, H: 64}, 0))
	}
	return terrain
}

func generateFinaleRoom(room RoomInfo, nextID *int) ([]Terrain, Vec) {
	offset := room.Bounds.X
	terrain := []Terrain{
		addTerrain(nextID, TerrainWall, Rect{X: offset, Y: 650, W: RoomW, H: 70}, 0),
		addTerrain(nextID, TerrainPlatform, Rect{X: offset + 174, Y: 570, W: 124, H: 18}, 0),
		addTerrain(nextID, TerrainPlatform, Rect{X: offset + 330, Y: 480, W: 112, H: 18}, 0),
		addTerrain(nextID, TerrainPillar, Rect{X: offset + 476, Y: 420, W: 46, H: 230}, 0),
		addTerrain(nextID, TerrainPlatform, Rect{X: offset + 538, Y: 370, W: 102, H: 18}, 0),
		addTerrain(nextID, TerrainWall, Rect{X: offset + 620, Y: 430, W: 20, H: 220}, 0),
	}
	return terrain, Vec{X: offset + 582, Y: 349}
}

func roomSpawns(room RoomInfo) []EnemySpawn {
	offset := room.Bounds.X
	switch room.Role {
	case RoomCombat:
		return []EnemySpawn{
			{Room: room.Index, Archetype: EnemyStalker, Pos: Vec{X: offset + 458, Y: 638}, Cost: 2},
			{Room: room.Index, Archetype: EnemyKite, Pos: Vec{X: offset + 514, Y: 414}, Cost: 2},
		}
	case RoomEscalation:
		return []EnemySpawn{
			{Room: room.Index, Archetype: EnemyStalker, Pos: Vec{X: offset + 404, Y: 638}, Cost: 2},
			{Room: room.Index, Archetype: EnemyKite, Pos: Vec{X: offset + 560, Y: 390}, Cost: 2},
			{Room: room.Index, Archetype: EnemyGuardian, Pos: Vec{X: offset + 594, Y: 636}, Cost: 3},
		}
	default:
		return nil
	}
}

func buildNavigation(terrain []Terrain, rooms []RoomInfo) ([]NavNode, []NavLink) {
	nodes := make([]NavNode, 0, len(terrain)*2)
	for _, terrain := range terrain {
		if terrain.Kind != TerrainWall && terrain.Kind != TerrainPlatform && terrain.Kind != TerrainPillar {
			continue
		}
		room := int(terrain.Bounds.X / RoomW)
		if room < 0 || room >= len(rooms) {
			continue
		}
		y := terrain.Bounds.Y
		inset := math.Min(16, terrain.Bounds.W/3)
		for _, x := range []float64{terrain.Bounds.X + inset, terrain.Bounds.X + terrain.Bounds.W - inset} {
			nodes = append(nodes, NavNode{ID: len(nodes), Room: room, Pos: Vec{X: x, Y: y}})
		}
	}
	links := make([]NavLink, 0, len(nodes)*3)
	for _, from := range nodes {
		for _, to := range nodes {
			if from.ID == to.ID {
				continue
			}
			dx, rise := math.Abs(to.Pos.X-from.Pos.X), from.Pos.Y-to.Pos.Y
			if dx <= MaxJumpRun && rise <= 92 && rise >= -220 {
				links = append(links, NavLink{From: from.ID, To: to.ID})
			}
		}
	}
	sort.Slice(links, func(i, j int) bool {
		if links[i].From == links[j].From {
			return links[i].To < links[j].To
		}
		return links[i].From < links[j].From
	})
	return nodes, links
}

func validateRunLayout(layout *RunLayout) bool {
	if len(layout.Rooms) != RoomCount || len(layout.Terrain) == 0 || layout.WardenPos.X == 0 {
		return false
	}
	for _, room := range layout.Rooms {
		if room.Bounds.W != RoomW || room.Entry.X >= room.Exit.X || !routeReachable(layout, room.Entry, room.Exit) {
			return false
		}
		if room.Role != RoomFinale && (!room.BirdShortcut || !hasRoomTerrain(layout, room.Index, TerrainWater)) {
			return false
		}
	}
	if !routeReachable(layout, layout.Rooms[0].Entry, layout.WardenPos) {
		return false
	}
	for _, spawn := range layout.Spawns {
		if spawn.Room < 0 || spawn.Room >= RoomCount || spawn.Cost <= 0 || spawnInInvalidTerrain(layout.Terrain, spawn) {
			return false
		}
	}
	return true
}

func hasRoomTerrain(layout *RunLayout, room int, kind TerrainKind) bool {
	left, right := float64(room)*RoomW, float64(room+1)*RoomW
	for _, terrain := range layout.Terrain {
		if terrain.Kind == kind && terrain.Bounds.X >= left && terrain.Bounds.X < right {
			return true
		}
	}
	return false
}

func spawnInInvalidTerrain(terrain []Terrain, spawn EnemySpawn) bool {
	radius := archetypeRules(spawn.Archetype).Radius
	for _, feature := range terrain {
		if (feature.solid() || feature.Kind == TerrainWater) && feature.Bounds.overlapsCircle(spawn.Pos, radius) {
			return true
		}
	}
	return false
}

func routeReachable(layout *RunLayout, start, end Vec) bool {
	if len(layout.NavNodes) == 0 {
		return false
	}
	startNode, endNode := nearestNavNode(layout.NavNodes, start), nearestNavNode(layout.NavNodes, end)
	if startNode < 0 || endNode < 0 {
		return false
	}
	edges := make(map[int][]int, len(layout.NavNodes))
	for _, link := range layout.NavLinks {
		edges[link.From] = append(edges[link.From], link.To)
	}
	seen, queue := map[int]bool{startNode: true}, []int{startNode}
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		if id == endNode {
			return true
		}
		for _, next := range edges[id] {
			if !seen[next] {
				seen[next] = true
				queue = append(queue, next)
			}
		}
	}
	return false
}

func nearestNavNode(nodes []NavNode, point Vec) int {
	closest, closestDistance := -1, math.MaxFloat64
	for _, node := range nodes {
		distance := node.Pos.Distance(point)
		if distance < closestDistance {
			closest, closestDistance = node.ID, distance
		}
	}
	return closest
}

func (l RunLayout) String() string {
	return fmt.Sprintf("seed=%x attempt=%d rooms=%d", l.Seed, l.Attempt, len(l.Rooms))
}
