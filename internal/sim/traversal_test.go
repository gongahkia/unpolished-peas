package sim

import "testing"

func testTraversalWorld() *World {
	w := NewRunWorld(99)
	w.Terrain = []Terrain{{ID: 1, Kind: TerrainSolid, Bounds: Rect{X: 0, Y: 500, W: ArenaW, H: 220}}}
	w.Objects = nil
	w.Enemies = nil
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

func TestFreshRunHasASafeIdleStart(t *testing.T) {
	world := NewRunWorld(0x72)
	step(world, InputFrame{}, 180)
	if world.Lost || world.Won || !world.Player.Grounded {
		t.Fatalf("fresh run did not preserve a safe idle start: player=%+v lost=%t won=%t", world.Player, world.Lost, world.Won)
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

func TestWallSlideAndLedgeGrabStayPredictable(t *testing.T) {
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

func TestDownJumpStartsSmashAndBreaksFloor(t *testing.T) {
	world := testTraversalWorld()
	world.Player.Pos, world.Player.Grounded, world.Player.State, world.Player.Velocity = Vec{X: 120, Y: 400}, false, TraversalAirborne, Vec{}
	world.Step(InputFrame{Down: true, Jump: true})
	if world.Player.State != TraversalDiving || world.Player.Velocity.Y < 6 || world.Player.JumpBuffer != 0 {
		t.Fatalf("down+jump did not start a committed downward smash: %+v", world.Player)
	}

	world = testTraversalWorld()
	world.Terrain = []Terrain{{ID: 2, Kind: TerrainBreakable, Bounds: Rect{X: 100, Y: 500, W: 60, H: 30}, HP: 1}}
	world.Player.Pos, world.Player.Velocity, world.Player.State = Vec{X: 120, Y: 480}, Vec{Y: 7}, TraversalDiving
	world.Player.Grounded = false
	step(world, InputFrame{}, 3)
	if world.Terrain[0].HP != 0 || world.Player.Grounded {
		t.Fatalf("dive did not break through marked floor: terrain=%+v player=%+v", world.Terrain[0], world.Player)
	}
}

func TestObjectsLinkCarryAndThrow(t *testing.T) {
	world := testTraversalWorld()
	crate := WorldObject{ID: 1, Kind: ObjectCrate, Pos: Vec{X: 200, Y: 486}, Size: Vec{X: 22, Y: 28}}
	plate := WorldObject{ID: 2, Kind: ObjectPlate, Pos: Vec{X: 200, Y: 496}, Size: Vec{X: 42, Y: 8}}
	door := WorldObject{ID: 3, Kind: ObjectDoor, Pos: Vec{X: 270, Y: 462}, Size: Vec{X: 28, Y: 76}, LinkID: plate.ID}
	world.Objects = []WorldObject{crate, plate, door}
	world.updateLinks()
	if !world.Objects[2].Active {
		t.Fatal("pressure plate did not open linked door")
	}

	world.Player.Pos = crate.Pos
	world.Step(InputFrame{Interact: true})
	if world.Player.HeldObjectID != crate.ID {
		t.Fatalf("player did not carry crate: %+v", world.Player)
	}
	world.Step(InputFrame{})
	world.Step(InputFrame{Throw: true, AimX: 1})
	if world.Player.HeldObjectID >= 0 || world.Objects[0].Held || world.Objects[0].Vel.X <= 0 || world.Stats.ObjectsThrown != 1 {
		t.Fatalf("throw did not release carried object: player=%+v crate=%+v stats=%+v", world.Player, world.Objects[0], world.Stats)
	}
}

func TestTraversalReplayStaysDeterministic(t *testing.T) {
	world := NewRunWorld(99)
	replay := NewReplay(world.Seed)
	for tick := 0; tick < 90; tick++ {
		input := InputFrame{MoveX: 1, AimX: 1}
		if tick == 3 || tick == 19 {
			input.Jump = true
		}
		if tick == 30 {
			input.Down, input.Jump = true, true
		}
		replay.Record(world, input)
	}
	if _, err := replay.PlayRun(); err != nil {
		t.Fatalf("traversal replay diverged: %v", err)
	}
	before := world.StateHash()
	for range 10 {
		_ = world.Snapshot()
	}
	if world.StateHash() != before {
		t.Fatal("render snapshots mutated deterministic run state")
	}
}
