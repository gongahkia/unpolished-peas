package sim

import (
	"fmt"
	"math"
)

const RunVersion = "72-run-2"

type RoomTemplate uint8

const (
	RoomOpen RoomTemplate = iota
	RoomStairs
	RoomSplit
	RoomRidge
	RoomHazardBridge
	RoomBreakout
	RoomColumn
	RoomPocket
	RoomDescent
	RoomFinale
)

func (t RoomTemplate) String() string {
	switch t {
	case RoomStairs:
		return "stairs"
	case RoomSplit:
		return "split"
	case RoomRidge:
		return "ridge"
	case RoomHazardBridge:
		return "hazard bridge"
	case RoomBreakout:
		return "breakout"
	case RoomColumn:
		return "column"
	case RoomPocket:
		return "pocket"
	case RoomDescent:
		return "descent"
	case RoomFinale:
		return "finale"
	default:
		return "open"
	}
}

type RunRoom struct {
	Index        int
	Template     RoomTemplate
	Bounds       Rect
	Entry, Exit  Vec
	Variant      int
	ThreatBudget int
}

type EnemyArchetype uint8

const (
	EnemyCharger EnemyArchetype = iota
	EnemyHopper
	EnemyDiver
)

func (a EnemyArchetype) String() string {
	switch a {
	case EnemyHopper:
		return "hopper"
	case EnemyDiver:
		return "diver"
	default:
		return "charger"
	}
}

type EnemySpawn struct {
	Room      int
	Archetype EnemyArchetype
	Pos       Vec
}

type RunStats struct {
	RoomsReached    int
	Treasure        int
	EnemiesDefeated int
	ObjectsThrown   int
	TerrainBroken   int
}

type RunLayout struct {
	Seed    uint64
	Rooms   []RunRoom
	Terrain []Terrain
	Objects []WorldObject
	Spawns  []EnemySpawn
	Start   Vec
	Exit    Vec
	Valid   bool
}

func (l RunLayout) String() string {
	return fmt.Sprintf("seed=%x rooms=%d terrain=%d objects=%d spawns=%d", l.Seed, len(l.Rooms), len(l.Terrain), len(l.Objects), len(l.Spawns))
}

type runRNG struct{ state uint64 }

func newRunRNG(seed uint64) *runRNG {
	if seed == 0 {
		seed = 1
	}
	return &runRNG{state: seed}
}

func (r *runRNG) next() uint64 {
	r.state ^= r.state << 13
	r.state ^= r.state >> 7
	r.state ^= r.state << 17
	return r.state
}

func (r *runRNG) intn(limit int) int {
	if limit < 2 {
		return 0
	}
	return int(r.next() % uint64(limit))
}

func (r *runRNG) shuffle(templates []RoomTemplate) {
	for index := len(templates) - 1; index > 0; index-- {
		other := r.intn(index + 1)
		templates[index], templates[other] = templates[other], templates[index]
	}
}

// GenerateRun combines authored room topologies with deterministic population
// choices. Every room retains a floor-level route; elevated paths, hazards,
// objects, and treasure create optional risk rather than required tricks.
func GenerateRun(seed uint64) RunLayout {
	if seed == 0 {
		seed = 1
	}
	rng := newRunRNG(seed)
	templates := []RoomTemplate{RoomOpen, RoomStairs, RoomSplit, RoomRidge, RoomHazardBridge, RoomBreakout, RoomColumn, RoomPocket, RoomDescent}
	rng.shuffle(templates)
	templates = append(templates, RoomFinale)

	layout := RunLayout{Seed: seed, Start: Vec{X: 52, Y: 639}, Exit: Vec{X: ArenaW - 42, Y: 626}}
	nextTerrainID, nextObjectID := 1, 1
	addTerrain := func(kind TerrainKind, bounds Rect, hp int) {
		layout.Terrain = append(layout.Terrain, Terrain{ID: nextTerrainID, Kind: kind, Bounds: bounds, HP: hp})
		nextTerrainID++
	}
	addObject := func(kind ObjectKind, pos, size Vec) int {
		id := nextObjectID
		layout.Objects = append(layout.Objects, WorldObject{ID: nextObjectID, Kind: kind, Pos: pos, Size: size})
		nextObjectID++
		return id
	}
	linkObjects := func(sourceID, targetID int) {
		layout.Objects[sourceID-1].LinkID = targetID
		layout.Objects[targetID-1].LinkID = sourceID
	}
	addSpawn := func(room int, archetype EnemyArchetype, pos Vec) {
		layout.Spawns = append(layout.Spawns, EnemySpawn{Room: room, Archetype: archetype, Pos: pos})
	}

	for index, template := range templates {
		offset := float64(index) * RoomW
		room := RunRoom{
			Index:        index,
			Template:     template,
			Bounds:       Rect{X: offset, Y: 0, W: RoomW, H: ArenaH},
			Entry:        Vec{X: offset + 48, Y: 639},
			Exit:         Vec{X: offset + RoomW - 48, Y: 639},
			Variant:      rng.intn(3),
			ThreatBudget: runThreatBudget(index, template),
		}
		layout.Rooms = append(layout.Rooms, room)
		populateRoom(room, addTerrain, addObject, linkObjects, addSpawn)
		populateRoomEncounters(room, rng, layout.Terrain, addSpawn)
	}
	addObject(ObjectExit, layout.Exit, Vec{X: 34, Y: 48})
	layout.Valid = validateRunLayout(&layout)
	return layout
}

func runThreatBudget(index int, template RoomTemplate) int {
	if index == 0 {
		return 0
	}
	if template == RoomFinale {
		return 3
	}
	if index < 3 {
		return 1
	}
	return 2
}

func populateRoom(room RunRoom, addTerrain func(TerrainKind, Rect, int), addObject func(ObjectKind, Vec, Vec) int, linkObjects func(int, int), addSpawn func(int, EnemyArchetype, Vec)) {
	x := room.Bounds.X
	platform := func(localX, y, width float64) {
		addTerrain(TerrainPlatform, Rect{X: x + localX, Y: y, W: width, H: 16}, 0)
	}
	solid := func(localX, y, width, height float64) {
		addTerrain(TerrainSolid, Rect{X: x + localX, Y: y, W: width, H: height}, 0)
	}
	breakable := func(localX, y, width, height float64) {
		addTerrain(TerrainBreakable, Rect{X: x + localX, Y: y, W: width, H: height}, 1)
	}
	spikes := func(localX, y, width float64) {
		addTerrain(TerrainSpike, Rect{X: x + localX, Y: y, W: width, H: 16}, 0)
	}
	treasure := func(localX, y float64) { addObject(ObjectTreasure, Vec{X: x + localX, Y: y}, Vec{X: 12, Y: 12}) }
	rock := func(localX float64) { addObject(ObjectRock, Vec{X: x + localX, Y: 640}, Vec{X: 18, Y: 20}) }
	crate := func(localX float64) { addObject(ObjectCrate, Vec{X: x + localX, Y: 636}, Vec{X: 22, Y: 28}) }

	// The unbroken floor is the ordinary route. Every template places its more
	// interesting choice away from the entrance and exit safety zones.
	solid(0, 650, RoomW, 70)
	switch room.Template {
	case RoomOpen:
		platform(190, 560, 118)
		platform(380, 494, 122)
		treasure(435, 478)
		rock(300)
	case RoomStairs:
		platform(150, 588, 90)
		platform(276, 530, 92)
		platform(406, 472, 106)
		treasure(460, 456)
		crate(354)
	case RoomSplit:
		solid(252, 520, 32, 130)
		platform(304, 570, 104)
		platform(426, 500, 110)
		treasure(481, 484)
		rock(188)
	case RoomRidge:
		platform(170, 548, 132)
		platform(354, 442, 156)
		platform(470, 548, 88)
		treasure(420, 426)
		crate(292)
	case RoomHazardBridge:
		spikes(290, 634, 58)
		platform(226, 572, 112)
		platform(382, 532, 112)
		treasure(437, 516)
		rock(198)
	case RoomBreakout:
		breakable(326, 530, 32, 120)
		platform(228, 568, 88)
		platform(382, 486, 116)
		treasure(442, 470)
		crate(276)
	case RoomColumn:
		solid(292, 430, 42, 220)
		platform(160, 566, 106)
		platform(366, 504, 116)
		treasure(414, 488)
		rock(246)
	case RoomPocket:
		solid(404, 574, 122, 76)
		platform(206, 548, 124)
		platform(420, 472, 92)
		spikes(436, 558, 54)
		treasure(466, 456)
		crate(346)
		plateID := addObject(ObjectPlate, Vec{X: x + 394, Y: 646}, Vec{X: 42, Y: 8})
		doorID := addObject(ObjectDoor, Vec{X: x + 550, Y: 612}, Vec{X: 28, Y: 76})
		linkObjects(plateID, doorID)
	case RoomDescent:
		platform(168, 556, 110)
		platform(330, 600, 92)
		platform(438, 524, 102)
		treasure(482, 508)
		rock(286)
	case RoomFinale:
		platform(178, 572, 112)
		platform(350, 494, 116)
		platform(498, 556, 78)
		spikes(410, 634, 42)
		treasure(407, 478)
		crate(300)
	}
}

func populateRoomEncounters(room RunRoom, rng *runRNG, terrain []Terrain, addSpawn func(int, EnemyArchetype, Vec)) {
	if room.ThreatBudget == 0 {
		return
	}
	x := room.Bounds.X
	spawnPosition := func(archetype EnemyArchetype, preferred float64) Vec {
		xs := []float64{preferred, 500, 420, 360, 280, 200}
		ys := []float64{638}
		if archetype == EnemyDiver {
			ys = []float64{438, 380, 320}
		}
		for _, localX := range xs {
			for _, y := range ys {
				position := Vec{X: x + localX, Y: y}
				if runPositionClear(terrain, position) {
					return position
				}
			}
		}
		return Vec{X: x + 200, Y: ys[0]}
	}
	first := EnemyArchetype(rng.intn(3))
	addSpawn(room.Index, first, spawnPosition(first, 370+float64(rng.intn(3))*36))
	if room.ThreatBudget < 2 {
		return
	}
	second := EnemyArchetype((int(first) + 1 + rng.intn(2)) % 3)
	addSpawn(room.Index, second, spawnPosition(second, 500))
}

func validateRunLayout(layout *RunLayout) bool {
	return runValidationIssue(layout) == ""
}

func runValidationIssue(layout *RunLayout) string {
	if layout.Seed == 0 || len(layout.Rooms) != RoomCount || len(layout.Terrain) == 0 || layout.Start.X <= 0 || layout.Exit.X <= layout.Start.X {
		return "missing run bounds or room count"
	}
	seenTemplates := make(map[RoomTemplate]bool, RoomCount)
	treasureRooms := make(map[int]bool, RoomCount)
	for _, room := range layout.Rooms {
		if room.Index < 0 || room.Index >= RoomCount || room.Bounds.W != RoomW || room.Bounds.H != ArenaH || room.Entry.X >= room.Exit.X || !hasGroundRoute(layout.Terrain, room) {
			return fmt.Sprintf("room %d has no safe ground route", room.Index)
		}
		seenTemplates[room.Template] = true
	}
	for template := RoomOpen; template <= RoomFinale; template++ {
		if !seenTemplates[template] {
			return fmt.Sprintf("missing template %s", template)
		}
	}
	objects := make(map[int]WorldObject, len(layout.Objects))
	for _, object := range layout.Objects {
		if object.ID == 0 || object.Size.X <= 0 || object.Size.Y <= 0 || object.Pos.X < 0 || object.Pos.X > ArenaW || !runPositionClear(layout.Terrain, object.Pos) {
			return fmt.Sprintf("object %d (%s) is invalid at %+v", object.ID, object.Kind, object.Pos)
		}
		objects[object.ID] = object
		if object.Kind == ObjectTreasure {
			treasureRooms[int(object.Pos.X/RoomW)] = true
		}
	}
	for _, object := range layout.Objects {
		if object.Kind == ObjectDoor && objects[object.LinkID].Kind != ObjectPlate {
			return fmt.Sprintf("door %d has no linked plate", object.ID)
		}
	}
	if len(treasureRooms) < RoomCount-2 {
		return "too few treasure rooms"
	}
	for _, spawn := range layout.Spawns {
		if spawn.Room < 0 || spawn.Room >= RoomCount || !runPositionClear(layout.Terrain, spawn.Pos) {
			return fmt.Sprintf("spawn %s in room %d is invalid at %+v", spawn.Archetype, spawn.Room, spawn.Pos)
		}
	}
	if math.Abs(layout.Exit.X-(ArenaW-42)) >= .01 {
		return "exit does not match final room"
	}
	return ""
}

func hasGroundRoute(terrain []Terrain, room RunRoom) bool {
	for _, feature := range terrain {
		if feature.Kind == TerrainSolid && feature.Bounds.Y == 650 && feature.Bounds.X <= room.Entry.X && feature.Bounds.X+feature.Bounds.W >= room.Exit.X {
			return true
		}
	}
	return false
}

func runPositionClear(terrain []Terrain, position Vec) bool {
	for _, feature := range terrain {
		if feature.solid() && feature.Bounds.contains(position) {
			return false
		}
		if feature.Kind == TerrainSpike && feature.Bounds.contains(position) {
			return false
		}
	}
	return true
}
