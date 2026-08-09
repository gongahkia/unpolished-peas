package sim

import (
	"fmt"
	"math"
)

const GeneratorVersion = "72-lab-2"

type LabModule uint8

const (
	ModuleJump LabModule = iota
	ModuleRoll
	ModuleWall
	ModuleVine
	ModuleCarry
	ModuleTeleport
	ModuleSlam
	ModuleTether
)

func (m LabModule) String() string {
	switch m {
	case ModuleJump:
		return "jump"
	case ModuleRoll:
		return "roll"
	case ModuleWall:
		return "wall"
	case ModuleVine:
		return "vine"
	case ModuleCarry:
		return "carry"
	case ModuleTeleport:
		return "teleport"
	case ModuleSlam:
		return "slam"
	default:
		return "tether"
	}
}

type LabModuleInfo struct {
	Kind    LabModule
	Bounds  Rect
	Variant int
}

type ObjectKind uint8

const (
	ObjectCrate ObjectKind = iota
	ObjectRock
	ObjectPlate
	ObjectDoor
	ObjectVineNode
	ObjectVine
	ObjectTeleporter
	ObjectSwitch
	ObjectExit
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
	case ObjectVineNode:
		return "vine node"
	case ObjectVine:
		return "vine"
	case ObjectTeleporter:
		return "teleporter"
	case ObjectSwitch:
		return "switch"
	default:
		return "exit"
	}
}

// WorldObject is deterministic physical or linked lab geometry. Pos is its
// centre except vines, whose Size supplies their climbable extent.
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

func (o WorldObject) movable() bool   { return o.Kind == ObjectCrate || o.Kind == ObjectRock }
func (o WorldObject) climbable() bool { return o.Kind == ObjectVine }

type LabLayout struct {
	Seed    uint64
	Attempt int
	Terrain []Terrain
	Objects []WorldObject
	Modules []LabModuleInfo
	Start   Vec
	Exit    Vec
	Valid   bool
}

type labRNG struct{ state uint64 }

func newLabRNG(seed uint64) *labRNG {
	if seed == 0 {
		seed = 1
	}
	return &labRNG{state: seed}
}

func (r *labRNG) next() uint64 {
	r.state ^= r.state << 13
	r.state ^= r.state >> 7
	r.state ^= r.state << 17
	return r.state
}

func (r *labRNG) intn(limit int) int {
	if limit < 2 {
		return 0
	}
	return int(r.next() % uint64(limit))
}

// GenerateMovementLab creates a compact obstacle grammar. The module set is
// invariant, while offsets, platform heights, object placement, and trial
// ordering within each lane vary per seed.
func GenerateMovementLab(seed uint64) LabLayout {
	layout := generateMovementLab(seed)
	layout.Valid = validateMovementLab(&layout)
	return layout
}

func generateMovementLab(seed uint64) LabLayout {
	rng := newLabRNG(seed)
	layout := LabLayout{Seed: seed, Start: Vec{X: 52, Y: 639}, Exit: Vec{X: ArenaW - 42, Y: 628}}
	nextTerrain, nextObject := 1, 1
	addTerrain := func(kind TerrainKind, bounds Rect, hp int) {
		layout.Terrain = append(layout.Terrain, Terrain{ID: nextTerrain, Kind: kind, Bounds: bounds, HP: hp})
		nextTerrain++
	}
	addObject := func(kind ObjectKind, pos, size Vec, link int) int {
		id := nextObject
		nextObject++
		layout.Objects = append(layout.Objects, WorldObject{ID: id, Kind: kind, Pos: pos, Size: size, LinkID: link})
		return id
	}
	addModule := func(kind LabModule, x float64, variant int) {
		layout.Modules = append(layout.Modules, LabModuleInfo{Kind: kind, Bounds: Rect{X: x, Y: 0, W: RoomW, H: ArenaH}, Variant: variant})
	}

	// Stable ground preserves a safe ordinary route; every module adds a more
	// expressive shortcut, gate, or alternate vertical line above it.
	for room := 0; room < RoomCount; room++ {
		x := float64(room) * RoomW
		addTerrain(TerrainSolid, Rect{X: x, Y: 650, W: RoomW, H: 70}, 0)
	}

	variant := rng.intn(3)
	addModule(ModuleJump, 0, variant)
	addModule(ModuleRoll, 0, (variant+1)%3)
	addModule(ModuleWall, 0, (variant+2)%3)
	addTerrain(TerrainPlatform, Rect{X: 78, Y: 570 - float64(variant)*12, W: 84, H: 16}, 0)
	addTerrain(TerrainPlatform, Rect{X: 336, Y: 500 + float64(variant)*10, W: 106, H: 16}, 0)
	addTerrain(TerrainSolid, Rect{X: 188, Y: 610, W: 132, H: 22}, 0) // roll-only tunnel
	addTerrain(TerrainSolid, Rect{X: 482, Y: 430, W: 30, H: 220}, 0) // wall-climb shaft
	addTerrain(TerrainPlatform, Rect{X: 528, Y: 464, W: 92, H: 16}, 0)
	addTerrain(TerrainPlatform, Rect{X: 548, Y: 382, W: 72, H: 16}, 0)

	variant = rng.intn(3)
	addModule(ModuleVine, RoomW, variant)
	addModule(ModuleCarry, RoomW, (variant+1)%3)
	addTerrain(TerrainSolid, Rect{X: 922, Y: 420, W: 34, H: 230}, 0)
	addTerrain(TerrainPlatform, Rect{X: 984, Y: 414 + float64(variant)*12, W: 132, H: 16}, 0)
	addObject(ObjectVineNode, Vec{X: 760 + float64(variant)*18, Y: 634}, Vec{X: 22, Y: 18}, 0)
	plateID := addObject(ObjectPlate, Vec{X: 1204, Y: 642}, Vec{X: 42, Y: 8}, 0)
	addObject(ObjectCrate, Vec{X: 1118, Y: 632}, Vec{X: 22, Y: 28}, plateID)
	addObject(ObjectRock, Vec{X: 1164, Y: 636}, Vec{X: 18, Y: 20}, plateID)
	doorLink := addObject(ObjectDoor, Vec{X: 1328, Y: 588}, Vec{X: 28, Y: 124}, plateID)
	layout.Objects[plateID-1].LinkID = doorLink

	variant = rng.intn(3)
	addModule(ModuleTeleport, RoomW*2, variant)
	addModule(ModuleSlam, RoomW*2, (variant+1)%3)
	teleA := addObject(ObjectTeleporter, Vec{X: 1472, Y: 628}, Vec{X: 26, Y: 38}, 0)
	teleB := addObject(ObjectTeleporter, Vec{X: 1810 + float64(variant)*16, Y: 478}, Vec{X: 26, Y: 38}, teleA)
	layout.Objects[teleA-1].LinkID = teleB
	addTerrain(TerrainPlatform, Rect{X: 1740, Y: 510, W: 178, H: 16}, 0)
	addTerrain(TerrainBreakable, Rect{X: 1984, Y: 620, W: 96, H: 30}, 1)
	addTerrain(TerrainPlatform, Rect{X: 1958, Y: 548, W: 148, H: 16}, 0)
	addTerrain(TerrainPit, Rect{X: 2020, Y: 650, W: 72, H: 70}, 0)
	addTerrain(TerrainSolid, Rect{X: 2020, Y: 692, W: 72, H: 28}, 0)

	variant = rng.intn(3)
	addModule(ModuleTether, RoomW*4, (variant+1)%3)
	addTerrain(TerrainSolid, Rect{X: 2204, Y: 386, W: 42, H: 264}, 0)
	addTerrain(TerrainPlatform, Rect{X: 2282, Y: 430 + float64(variant)*14, W: 122, H: 16}, 0)
	addTerrain(TerrainWater, Rect{X: 2404, Y: 650, W: 142, H: 70}, 0)
	addTerrain(TerrainPlatform, Rect{X: 2440, Y: 570, W: 76, H: 16}, 0)
	addTerrain(TerrainSolid, Rect{X: 2782, Y: 492, W: 28, H: 158}, 0) // aperture wall
	addTerrain(TerrainSolid, Rect{X: 2866, Y: 450, W: 26, H: 200}, 0)
	switchID := addObject(ObjectSwitch, Vec{X: 2836, Y: 540}, Vec{X: 16, Y: 18}, 0)
	exitDoor := addObject(ObjectDoor, Vec{X: 3052, Y: 588}, Vec{X: 28, Y: 124}, switchID)
	layout.Objects[switchID-1].LinkID = exitDoor
	addObject(ObjectExit, layout.Exit, Vec{X: 36, Y: 48}, 0)

	return layout
}

func validateMovementLab(layout *LabLayout) bool {
	if layout.Seed == 0 || len(layout.Terrain) == 0 || layout.Start.X <= 0 || layout.Exit.X <= layout.Start.X {
		return false
	}
	required := map[LabModule]bool{}
	for _, module := range layout.Modules {
		required[module.Kind] = true
		if module.Bounds.W != RoomW || module.Bounds.H != ArenaH {
			return false
		}
	}
	for kind := ModuleJump; kind <= ModuleTether; kind++ {
		if !required[kind] {
			return false
		}
	}
	objects := make(map[int]WorldObject, len(layout.Objects))
	for _, object := range layout.Objects {
		if object.ID == 0 || object.Size.X <= 0 || object.Size.Y <= 0 || object.Pos.X < 0 || object.Pos.X > ArenaW {
			return false
		}
		objects[object.ID] = object
	}
	for _, object := range layout.Objects {
		if object.Kind == ObjectDoor && objects[object.LinkID].ID == 0 {
			return false
		}
	}
	return math.Abs(layout.Exit.X-ArenaW+42) < 0.01
}

func (l LabLayout) String() string {
	return fmt.Sprintf("seed=%x modules=%d objects=%d", l.Seed, len(l.Modules), len(l.Objects))
}
