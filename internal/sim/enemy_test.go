package sim

import "testing"

func testActionWorld() *World {
	world := NewRunWorld(1)
	world.Terrain = []Terrain{{ID: 1, Kind: TerrainSolid, Bounds: Rect{X: 0, Y: 500, W: ArenaW, H: 220}}}
	world.Objects = nil
	world.Enemies = nil
	world.Player = newPlayer()
	world.Player.Pos = Vec{X: 80, Y: 489}
	world.Player.Grounded = true
	world.Player.State = TraversalGrounded
	return world
}

func TestChargerBreaksFragileTerrainButStopsAtSolid(t *testing.T) {
	world := testActionWorld()
	world.Terrain = append(world.Terrain, Terrain{ID: 2, Kind: TerrainBreakable, Bounds: Rect{X: 170, Y: 400, W: 24, H: 100}, HP: 1})
	charger := newEnemy(1, EnemySpawn{Archetype: EnemyCharger, Pos: Vec{X: 150, Y: 488}})
	charger.State, charger.Timer, charger.Facing, charger.Grounded = EnemyCharge, 10, 1, true
	world.Enemies = []Enemy{charger}
	for range 4 {
		world.updateEnemies()
	}
	if world.Terrain[1].HP != 0 || world.Stats.TerrainBroken != 1 {
		t.Fatalf("charger did not break fragile terrain: terrain=%+v stats=%+v", world.Terrain[1], world.Stats)
	}

	world = testActionWorld()
	world.Terrain = append(world.Terrain, Terrain{ID: 2, Kind: TerrainSolid, Bounds: Rect{X: 170, Y: 400, W: 24, H: 100}})
	charger = newEnemy(1, EnemySpawn{Archetype: EnemyCharger, Pos: Vec{X: 150, Y: 488}})
	charger.State, charger.Timer, charger.Facing, charger.Grounded = EnemyCharge, 10, 1, true
	world.Enemies = []Enemy{charger}
	for range 4 {
		world.updateEnemies()
	}
	if world.Enemies[0].State != EnemyRecover || world.Enemies[0].Pos.X > 170-world.Enemies[0].Size.X/2 {
		t.Fatalf("charger did not stop at solid terrain: %+v", world.Enemies[0])
	}
}

func TestRockImpactAndHazardDefeatEnemies(t *testing.T) {
	world := testActionWorld()
	rock := WorldObject{ID: 1, Kind: ObjectRock, Pos: Vec{X: 120, Y: 490}, Size: Vec{X: 18, Y: 20}, Vel: Vec{X: 8}}
	enemy := newEnemy(2, EnemySpawn{Archetype: EnemyCharger, Pos: Vec{X: 145, Y: 488}})
	enemy.Grounded = true
	world.Objects = []WorldObject{rock}
	world.Enemies = []Enemy{enemy}
	world.updateObjects()
	if !world.Enemies[0].Dead || world.Stats.EnemiesDefeated != 1 {
		t.Fatalf("fast rock did not defeat enemy: enemy=%+v stats=%+v", world.Enemies[0], world.Stats)
	}

	world = testActionWorld()
	world.Terrain = append(world.Terrain, Terrain{ID: 2, Kind: TerrainSpike, Bounds: Rect{X: 130, Y: 480, W: 40, H: 20}})
	enemy = newEnemy(1, EnemySpawn{Archetype: EnemyHopper, Pos: Vec{X: 145, Y: 489}})
	world.Enemies = []Enemy{enemy}
	world.applyHazards()
	if !world.Enemies[0].Dead || world.Stats.EnemiesDefeated != 1 {
		t.Fatalf("hazard did not defeat enemy: enemy=%+v stats=%+v", world.Enemies[0], world.Stats)
	}
}

func TestHopperAndDiverUseReadableTelegraphs(t *testing.T) {
	world := testActionWorld()
	hopper := newEnemy(1, EnemySpawn{Archetype: EnemyHopper, Pos: Vec{X: 180, Y: 490}})
	hopper.Grounded, hopper.Timer = true, 1
	world.Enemies = []Enemy{hopper}
	world.updateEnemies()
	if world.Enemies[0].Vel.Y >= 0 {
		t.Fatalf("hopper did not begin its rhythmic jump: %+v", world.Enemies[0])
	}

	world = testActionWorld()
	world.Player.Pos = Vec{X: 180, Y: 380}
	diver := newEnemy(1, EnemySpawn{Archetype: EnemyDiver, Pos: Vec{X: 80, Y: 280}})
	diver.Timer = 1
	world.Enemies = []Enemy{diver}
	world.updateEnemies()
	if world.Enemies[0].State != EnemyTelegraph || world.Enemies[0].Timer != 28 {
		t.Fatalf("diver did not telegraph before diving: %+v", world.Enemies[0])
	}
	for range 28 {
		world.updateEnemies()
	}
	if world.Enemies[0].State != EnemyDive {
		t.Fatalf("diver did not commit after telegraph: %+v", world.Enemies[0])
	}
}

func TestStompAndThrownRockCreateTraversalCombatOptions(t *testing.T) {
	world := testActionWorld()
	enemy := newEnemy(1, EnemySpawn{Archetype: EnemyHopper, Pos: Vec{X: 120, Y: 489}})
	world.Enemies = []Enemy{enemy}
	world.Player.Pos = Vec{X: 120, Y: 470}
	world.Player.Velocity.Y = 5
	world.Player.Grounded = false
	world.resolvePlayerEnemyContacts()
	if !world.Enemies[0].Dead || world.Player.Velocity.Y >= 0 {
		t.Fatalf("descending player did not stomp enemy: player=%+v enemy=%+v", world.Player, world.Enemies[0])
	}

	world = testActionWorld()
	rock := WorldObject{ID: 1, Kind: ObjectRock, Pos: Vec{X: 160, Y: 490}, Size: Vec{X: 18, Y: 20}, Held: true}
	plate := WorldObject{ID: 2, Kind: ObjectPlate, Pos: Vec{X: 200, Y: 496}, Size: Vec{X: 42, Y: 8}}
	door := WorldObject{ID: 3, Kind: ObjectDoor, Pos: Vec{X: 270, Y: 462}, Size: Vec{X: 28, Y: 76}, LinkID: plate.ID}
	world.Objects = []WorldObject{rock, plate, door}
	world.Player.HeldObjectID = rock.ID
	world.Player.Aim = Vec{X: 1}
	world.throwHeldObject()
	for range 8 {
		world.updateObjects()
		world.updateLinks()
	}
	if !world.Objects[1].Active || !world.Objects[2].Active {
		t.Fatalf("thrown rock did not trigger linked plate and door: %+v", world.Objects)
	}
}
