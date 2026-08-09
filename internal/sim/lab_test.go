package sim

import (
	"fmt"
	"testing"
)

func testTraversalWorld() *World {
	w := NewLabWorld(99)
	w.Terrain = []Terrain{{ID: 1, Kind: TerrainSolid, Bounds: Rect{X: 0, Y: 500, W: ArenaW, H: 220}}}
	w.Objects = nil
	w.Player = newPlayer()
	w.Player.Pos = Vec{X: 120, Y: 489}
	w.Player.Grounded = true
	w.Player.State = TraversalGrounded
	return w
}

func step(world *World, input InputFrame, count int) {
	for range count {
		world.Step(input)
	}
}

func TestMovementLabsAreDeterministicAndComplete(t *testing.T) {
	first, second := GenerateMovementLab(0x72), GenerateMovementLab(0x72)
	if !first.Valid || labFingerprint(first) != labFingerprint(second) {
		t.Fatalf("same seed did not generate a stable valid lab: %s / %s", first, second)
	}
	if labFingerprint(first) == labFingerprint(GenerateMovementLab(0x73)) {
		t.Fatal("different seeds produced identical lab geometry")
	}
	for seed := uint64(1); seed <= 1024; seed++ {
		layout := GenerateMovementLab(seed)
		if !layout.Valid || len(layout.Modules) != 8 || len(layout.Objects) < 8 {
			t.Fatalf("seed %d generated an invalid movement lab: %+v", seed, layout)
		}
	}
}

func TestFreshLabHasASafeIdleStart(t *testing.T) {
	world := NewLabWorld(0x72)
	step(world, InputFrame{}, 180)
	if world.Lost || world.Won || !world.Player.Grounded {
		t.Fatalf("fresh movement lab did not preserve a safe idle start: player=%+v lost=%t won=%t", world.Player, world.Lost, world.Won)
	}
}

func TestJumpBufferCoyoteVariableJumpAndDoubleJump(t *testing.T) {
	world := testTraversalWorld()
	world.Step(InputFrame{Jump: true})
	if world.Player.Grounded || world.Player.Velocity.Y >= 0 {
		t.Fatalf("ground jump did not launch: %+v", world.Player)
	}
	world.Step(InputFrame{})
	if world.Player.Velocity.Y >= -3.5 {
		t.Fatalf("jump release did not shorten ascent: velocity=%+v", world.Player.Velocity)
	}
	world.Step(InputFrame{Jump: true})
	if world.Player.AirJumps != 0 || world.Player.Velocity.Y >= -5 {
		t.Fatalf("double jump was unavailable: %+v", world.Player)
	}

	world = testTraversalWorld()
	world.Player.Grounded, world.Player.Coyote = false, coyoteTicks
	world.Step(InputFrame{Jump: true})
	if world.Player.Velocity.Y >= 0 {
		t.Fatalf("coyote jump did not launch: %+v", world.Player)
	}
}

func TestRollFitsLowTunnelAndDropPassesPlatform(t *testing.T) {
	world := testTraversalWorld()
	world.Terrain = append(world.Terrain,
		Terrain{ID: 2, Kind: TerrainSolid, Bounds: Rect{X: 160, Y: 460, W: 110, H: 22}},
		Terrain{ID: 3, Kind: TerrainPlatform, Bounds: Rect{X: 310, Y: 440, W: 120, H: 16}},
	)
	world.Step(InputFrame{Down: true})
	if !world.Player.Crouching || world.Player.Pos.Y != 493 {
		t.Fatalf("down did not lower the player collision body: %+v", world.Player)
	}
	world.Step(InputFrame{})
	step(world, InputFrame{MoveX: 1, Roll: true}, 35)
	if world.Player.Pos.X <= 270 {
		t.Fatalf("roll did not pass the low tunnel: %+v", world.Player)
	}

	world.Player.Pos, world.Player.Grounded, world.Player.Crouching, world.Player.Velocity = Vec{X: 350, Y: 429}, true, false, Vec{}
	world.Step(InputFrame{Jump: true, Down: true})
	step(world, InputFrame{Down: true}, 4)
	if world.Player.Pos.Y <= 429 {
		t.Fatalf("drop-through did not leave the platform: %+v", world.Player)
	}
}

func TestWallSlideLedgeGrabAndClimbableObjects(t *testing.T) {
	world := testTraversalWorld()
	world.Terrain = append(world.Terrain, Terrain{ID: 2, Kind: TerrainSolid, Bounds: Rect{X: 180, Y: 360, W: 24, H: 140}})
	world.Player.Pos, world.Player.Grounded, world.Player.Velocity = Vec{X: 172, Y: 440}, false, Vec{Y: 3}
	world.Step(InputFrame{MoveX: 1})
	if world.Player.State != TraversalWallCling || world.Player.WallDirection != 1 {
		t.Fatalf("wall contact did not enter cling state: %+v", world.Player)
	}
	world.Step(InputFrame{})
	world.Step(InputFrame{Jump: true})
	if world.Player.Velocity.X >= 0 || world.Player.Velocity.Y >= 0 || world.Player.WallTicks != 0 {
		t.Fatalf("wall-jump grace did not preserve a late jump: %+v", world.Player)
	}
	world.Objects = append(world.Objects, WorldObject{ID: 1, Kind: ObjectVine, Pos: Vec{X: 240, Y: 440}, Size: Vec{X: 10, Y: 120}})
	world.Player.Pos, world.Player.Velocity, world.Player.Grounded = Vec{X: 240, Y: 450}, Vec{}, false
	world.Step(InputFrame{Jump: true})
	if world.Player.State != TraversalClimbing || world.Player.ClimbObjectID != 1 {
		t.Fatalf("vine did not enter climb state: %+v", world.Player)
	}
	world = testTraversalWorld()
	world.Terrain = append(world.Terrain, Terrain{ID: 2, Kind: TerrainSolid, Bounds: Rect{X: 180, Y: 420, W: 36, H: 80}})
	world.Player.Pos, world.Player.Velocity, world.Player.Grounded = Vec{X: 170, Y: 430}, Vec{Y: 3}, false
	if !world.tryGrabLedge(1, world.Terrain[1].Bounds) || world.Player.State != TraversalLedgeGrab || world.Player.LedgeTicks == 0 {
		t.Fatalf("ledge contact did not enter a readable grab state: %+v", world.Player)
	}
	world.Step(InputFrame{Jump: true})
	step(world, InputFrame{}, 5)
	if !world.Player.Grounded || world.Player.State != TraversalGrounded || world.Player.Pos != (Vec{X: 170, Y: 409}) {
		t.Fatalf("ledge grab did not mantle to its stored landing position: %+v", world.Player)
	}
}

func TestLedgeGrabUsesTheWallThatBlockedMovement(t *testing.T) {
	world := testTraversalWorld()
	remote := Terrain{ID: 2, Kind: TerrainSolid, Bounds: Rect{X: 1000, Y: 420, W: 36, H: 80}}
	local := Terrain{ID: 3, Kind: TerrainSolid, Bounds: Rect{X: 180, Y: 420, W: 36, H: 80}}
	world.Terrain = append(world.Terrain, remote, local)
	world.Player.Pos = Vec{X: 170, Y: 430}
	world.Player.Velocity = Vec{X: 4, Y: 3}
	world.Player.Grounded = false
	world.Player.State = TraversalAirborne

	world.Step(InputFrame{})

	if world.Player.State != TraversalLedgeGrab {
		t.Fatalf("local wall contact did not enter ledge grab: %+v", world.Player)
	}
	if want := (Vec{X: 170, Y: 428}); world.Player.Pos != want {
		t.Fatalf("ledge grab moved to %+v, want local ledge %+v", world.Player.Pos, want)
	}
}

func TestDownJumpStartsSmash(t *testing.T) {
	world := testTraversalWorld()
	world.Player.Pos, world.Player.Grounded, world.Player.State, world.Player.Velocity = Vec{X: 120, Y: 400}, false, TraversalAirborne, Vec{}
	world.Step(InputFrame{Down: true, Jump: true})
	if world.Player.State != TraversalDiving || world.Player.Velocity.Y < 6 || world.Player.JumpBuffer != 0 {
		t.Fatalf("down+jump did not start a committed downward smash: %+v", world.Player)
	}
}

func TestDiveBreaksFloorAndVineActivates(t *testing.T) {
	world := testTraversalWorld()
	world.Terrain = []Terrain{{ID: 2, Kind: TerrainBreakable, Bounds: Rect{X: 100, Y: 500, W: 60, H: 30}, HP: 1}}
	world.Player.Pos, world.Player.Velocity, world.Player.State = Vec{X: 120, Y: 480}, Vec{Y: 7}, TraversalDiving
	world.Player.Grounded = false
	step(world, InputFrame{}, 3)
	if world.Terrain[0].HP != 0 || world.Player.Grounded {
		t.Fatalf("dive did not break through marked floor: terrain=%+v player=%+v", world.Terrain[0], world.Player)
	}

	world = NewLabWorld(5)
	var node *WorldObject
	for index := range world.Objects {
		if world.Objects[index].Kind == ObjectVineNode {
			node = &world.Objects[index]
			break
		}
	}
	if node == nil {
		t.Fatal("lab omitted vine node")
	}
	world.Player.Pos = node.Pos
	world.Step(InputFrame{Interact: true})
	if !node.Active || world.nearClimbable(node.Pos) == nil {
		t.Fatalf("vine interaction did not create a climbable route: node=%+v objects=%+v", node, world.Objects)
	}
}

func TestObjectsLinkCarryThrowTeleportAndTether(t *testing.T) {
	world := NewLabWorld(7)
	var crate, plate, door, teleporter, remote *WorldObject
	for index := range world.Objects {
		object := &world.Objects[index]
		switch object.Kind {
		case ObjectCrate:
			crate = object
		case ObjectPlate:
			plate = object
		case ObjectDoor:
			if door == nil {
				door = object
			}
		case ObjectTeleporter:
			teleporter = object
		case ObjectSwitch:
			remote = object
		}
	}
	if crate == nil || plate == nil || door == nil || teleporter == nil || remote == nil {
		t.Fatalf("required lab objects missing: %+v", world.Objects)
	}
	crate.Pos = plate.Pos
	world.updateLinks()
	if !door.Active {
		t.Fatal("pressure plate did not open linked door")
	}

	world.Player.Pos = crate.Pos
	world.Step(InputFrame{Interact: true})
	if world.Player.HeldObjectID != crate.ID {
		t.Fatalf("player did not carry crate: %+v", world.Player)
	}
	world.Step(InputFrame{})
	world.Step(InputFrame{Throw: true, AimX: 1})
	if world.Player.HeldObjectID >= 0 || crate.Held || crate.Vel.X <= 0 {
		t.Fatalf("throw did not release carried object: player=%+v crate=%+v", world.Player, crate)
	}

	world.Player.Pos = teleporter.Pos
	world.Step(InputFrame{Interact: true})
	if world.Player.Pos == teleporter.Pos {
		t.Fatal("teleporter did not move player")
	}
	world.Player.Pos = remote.Pos
	world.Player.Tether = TetherState{Active: true, Pos: remote.Pos}
	world.Step(InputFrame{})
	world.Step(InputFrame{Interact: true})
	if !remote.Active {
		t.Fatal("tether did not activate remote switch")
	}
}

func TestMovementReplayStaysDeterministic(t *testing.T) {
	world := NewLabWorld(99)
	replay := NewReplay(world.Seed)
	for tick := 0; tick < 90; tick++ {
		input := InputFrame{MoveX: 1, AimX: 1}
		if tick == 3 || tick == 19 {
			input.Jump = true
		}
		if tick == 30 {
			input.Down, input.Jump = true, true
		}
		if tick == 40 {
			input.Tether = true
		}
		replay.Record(world, input)
	}
	if _, err := replay.PlayLab(); err != nil {
		t.Fatalf("movement replay diverged: %v", err)
	}
	before := world.StateHash()
	for range 10 {
		_ = world.Snapshot()
	}
	if world.StateHash() != before {
		t.Fatal("render snapshots mutated deterministic lab state")
	}
}

func labFingerprint(layout LabLayout) string {
	fingerprint := layout.String()
	for _, module := range layout.Modules {
		fingerprint += fmt.Sprintf("/m%d/%d/%d", module.Kind, q(module.Bounds.X), module.Variant)
	}
	for _, terrain := range layout.Terrain {
		fingerprint += fmt.Sprintf("/t%d/%d/%d,%d,%d,%d", terrain.Kind, terrain.HP, q(terrain.Bounds.X), q(terrain.Bounds.Y), q(terrain.Bounds.W), q(terrain.Bounds.H))
	}
	for _, object := range layout.Objects {
		fingerprint += fmt.Sprintf("/o%d/%d/%d,%d/%d,%d/%d", object.ID, object.Kind, q(object.Pos.X), q(object.Pos.Y), q(object.Size.X), q(object.Size.Y), object.LinkID)
	}
	return fingerprint
}

func q(value float64) int64 { return int64(value * 1000) }
