package sim

import (
	"fmt"
	"hash/fnv"
	"math"
)

const SimulationVersion = RunVersion

// World is the deterministic authority for a procedural platforming run.
// Rendering and presentation never mutate this state.
type World struct {
	Seed, Tick uint64
	Player     Player
	Terrain    []Terrain
	Objects    []WorldObject
	Lab        LabLayout
	Run        RunLayout
	Stats      RunStats
	Won, Lost  bool
	Debug      bool
	Trauma     float64
	nextID     int
	prevInput  InputFrame
}

func NewLabWorld(seed uint64) *World {
	if seed == 0 {
		seed = 1
	}
	lab := GenerateMovementLab(seed)
	w := &World{Seed: seed, Lab: lab, Terrain: append([]Terrain(nil), lab.Terrain...), Objects: append([]WorldObject(nil), lab.Objects...), nextID: len(lab.Objects) + 1}
	w.Player = newPlayer()
	w.Player.Pos = lab.Start
	w.Player.Grounded = true
	w.Player.State = TraversalGrounded
	return w
}

func NewRunWorld(seed uint64) *World {
	if seed == 0 {
		seed = 1
	}
	run := GenerateRun(seed)
	w := &World{Seed: seed, Run: run, Terrain: append([]Terrain(nil), run.Terrain...), Objects: append([]WorldObject(nil), run.Objects...), nextID: len(run.Objects) + 1}
	w.Player = newPlayer()
	w.Player.Pos = run.Start
	w.Player.Grounded = true
	w.Player.State = TraversalGrounded
	w.Stats.RoomsReached = 1
	return w
}

func (w *World) nextObjectID() int { id := w.nextID; w.nextID++; return id }

func (w *World) Step(input InputFrame) {
	w.Tick++
	if input.DebugStep && !w.prevInput.DebugStep {
		w.Debug = !w.Debug
	}
	if w.Lost || w.Won {
		w.prevInput = input
		return
	}
	w.Trauma *= 0.82
	w.updateAim(input)
	w.beginTraversalInput(input)
	w.handleInteraction(input)
	w.handleObjectActions(input)
	w.updateTraversal(input)
	w.updateTether(input)
	w.updateHeldObject()
	w.updateObjects()
	w.updateLinks()
	w.collectTreasure()
	w.applyHazards()
	w.checkExit()
	w.updateRunStats()
	w.prevInput = input
}

func (w *World) updateAim(input InputFrame) {
	aim := Vec{X: float64(input.AimX), Y: float64(input.AimY)}
	if aim.LengthSq() > 1 {
		aim = aim.Normalized()
	}
	if aim.LengthSq() > 0 {
		w.Player.Aim = aim
	}
}

func decrement(value *int) {
	if *value > 0 {
		*value--
	}
}

func (w *World) beginTraversalInput(input InputFrame) {
	p := &w.Player
	decrement(&p.Coyote)
	decrement(&p.JumpBuffer)
	decrement(&p.RollCooldown)
	decrement(&p.DropTicks)
	decrement(&p.WallTicks)
	if input.Jump && !w.prevInput.Jump {
		p.JumpBuffer = jumpBufferTicks
	}
	if input.Down && input.Jump && !w.prevInput.Jump && p.Grounded && w.standingOnPlatform() {
		p.DropTicks = 10
		p.Grounded, p.JumpBuffer, p.Coyote = false, 0, 0
		p.Velocity.Y = 1.6
	}
	if input.Down && input.Jump && !w.prevInput.Jump && !p.Grounded && p.ClimbObjectID < 0 && p.State != TraversalLedgeGrab && !p.Tether.Active {
		p.JumpBuffer, p.Coyote = 0, 0
		p.State = TraversalDiving
		p.Velocity.Y = max(6, p.Velocity.Y+5)
	}
	if p.Grounded && input.Down && p.RollTicks == 0 && !p.Crouching {
		p.Pos.Y += playerStandHalfH - playerCrouchHalfH
		p.Crouching = true
	}
	if input.Roll && !w.prevInput.Roll && p.RollCooldown == 0 && p.ClimbObjectID < 0 && p.State != TraversalLedgeGrab {
		direction := p.Facing
		if input.MoveX != 0 {
			direction = input.MoveX
		}
		wasCrouching := p.Crouching
		p.Facing, p.RollTicks, p.RollCooldown, p.Crouching = direction, 11, 20, true
		if p.Grounded && !wasCrouching {
			p.Pos.Y += playerStandHalfH - playerCrouchHalfH
		}
		p.Velocity.X = float64(direction) * 7.4
		p.State = TraversalRolling
	}
	if input.Tether && !w.prevInput.Tether {
		p.Tether.Active = !p.Tether.Active
		p.Tether.Pos = p.Pos
	}
	if !input.Jump && w.prevInput.Jump && p.Velocity.Y < -4.2 {
		p.Velocity.Y = -4.2 // variable jump height
	}
	if p.RollTicks == 0 && p.Crouching && !input.Down {
		w.tryStand()
	}
}

func (w *World) tryStand() {
	p := &w.Player
	if !p.Grounded {
		return
	}
	target := p.Pos
	target.Y -= playerStandHalfH - playerCrouchHalfH
	bounds := Rect{X: target.X - playerHalfW, Y: target.Y - playerStandHalfH, W: playerHalfW * 2, H: playerStandHalfH * 2}
	if !w.boundsBlocked(bounds) {
		p.Pos, p.Crouching = target, false
	}
}

func (w *World) updateTraversal(input InputFrame) {
	p := &w.Player
	if p.State == TraversalLedgeGrab {
		if input.Down {
			p.State, p.LedgeTicks = TraversalAirborne, 0
			p.Velocity.Y = 1.6
			return
		}
		if (input.Jump && !w.prevInput.Jump) || input.MoveX == p.LedgeDirection {
			p.Pos, p.Velocity = p.LedgeTarget, Vec{}
			p.LedgeTicks, p.MantleTicks = 0, 5
			p.State = TraversalMantling
			return
		}
		decrement(&p.LedgeTicks)
		if p.LedgeTicks == 0 {
			p.State = TraversalAirborne
			p.Velocity.Y = 1.6
		}
		return
	}
	if p.MantleTicks > 0 {
		p.MantleTicks--
		p.State = TraversalMantling
		if p.MantleTicks == 0 {
			p.State, p.Grounded = TraversalGrounded, true
		}
		return
	}
	if p.ClimbObjectID >= 0 {
		if !w.climbInput(input) {
			p.ClimbObjectID = -1
		} else {
			p.State = TraversalClimbing
			vertical := 0.0
			if input.Jump {
				vertical -= 3.8
			}
			if input.Down {
				vertical += 3.2
			}
			p.Pos.Y += vertical
			p.Velocity = Vec{}
			p.Grounded = false
			if input.Jump && !w.prevInput.Jump && input.MoveX != 0 {
				p.ClimbObjectID = -1
				p.Velocity = Vec{X: float64(input.MoveX) * 6.1, Y: -9.2}
				p.AirJumps = 1
			}
			return
		}
	}

	if p.JumpBuffer > 0 {
		switch {
		case p.Grounded || p.Coyote > 0:
			p.Velocity.Y, p.Grounded, p.Coyote, p.JumpBuffer = -jumpVelocity, false, 0, 0
			p.State = TraversalAirborne
		case p.WallDirection != 0 && p.WallTicks > 0:
			p.Velocity = Vec{X: float64(-p.WallDirection) * 6.4, Y: -9.7}
			p.WallDirection, p.WallTicks, p.JumpBuffer, p.AirJumps = 0, 0, 0, 1
			p.State = TraversalAirborne
		case p.AirJumps > 0:
			p.Velocity.Y, p.AirJumps, p.JumpBuffer = -doubleJumpVelocity, p.AirJumps-1, 0
			p.State = TraversalAirborne
		}
	}

	direction := float64(input.MoveX)
	if input.MoveX != 0 {
		p.Facing = input.MoveX
	}
	if p.RollTicks > 0 {
		p.RollTicks--
		p.State = TraversalRolling
		direction = float64(p.Facing) * 1.35
	} else {
		p.Velocity.X += direction * moveAcceleration
		if direction == 0 {
			p.Velocity.X *= 0.72
		}
		p.Velocity.X = clamp(p.Velocity.X, -moveTopSpeed, moveTopSpeed)
	}
	p.Velocity.Y = min(15, p.Velocity.Y+Gravity)
	fallSpeed, wasDiving := p.Velocity.Y, p.State == TraversalDiving
	wall := w.movePlayer(Vec{X: p.Velocity.X, Y: p.Velocity.Y})
	if p.State == TraversalLedgeGrab {
		return
	}
	brokeFloor := wasDiving && w.breakFloorBelow(fallSpeed)
	if brokeFloor {
		p.Grounded, p.Velocity.Y = false, fallSpeed
	}
	wallSliding := wall != 0 && !p.Grounded && p.Velocity.Y > 0 && input.MoveX == wall && p.State != TraversalDiving
	if wallSliding {
		p.WallDirection, p.WallTicks = wall, wallJumpGraceTicks
		p.Velocity.Y = min(p.Velocity.Y, 1.35)
		p.State = TraversalWallCling
	} else if p.WallTicks == 0 {
		p.WallDirection = 0
	}
	if p.Grounded && !brokeFloor {
		p.State, p.AirJumps, p.Coyote, p.WallDirection, p.WallTicks = TraversalGrounded, 1, coyoteTicks, 0, 0
	} else if !wallSliding && p.State != TraversalDiving && p.RollTicks == 0 {
		p.State = TraversalAirborne
	}
	if p.RollTicks == 0 && p.State == TraversalRolling {
		p.State = TraversalAirborne
	}
	if !p.Grounded && p.ClimbObjectID < 0 && (input.Jump || input.Down) {
		if object := w.nearClimbable(p.Pos); object != nil {
			p.ClimbObjectID, p.State, p.Velocity = object.ID, TraversalClimbing, Vec{}
		}
	}
}

func (w *World) movePlayer(delta Vec) int8 {
	p := &w.Player
	position := p.Pos
	blocked := int8(0)
	blockingBounds := Rect{}
	next := position
	next.X = clamp(position.X+delta.X, playerHalfW, ArenaW-playerHalfW)
	for _, solid := range w.solidRects() {
		if !p.boundsAt(next).overlaps(solid) {
			continue
		}
		if delta.X > 0 {
			next.X = solid.X - playerHalfW
			blocked = 1
			blockingBounds = solid
		} else if delta.X < 0 {
			next.X = solid.X + solid.W + playerHalfW
			blocked = -1
			blockingBounds = solid
		}
		p.Velocity.X = 0
	}
	if blocked != 0 && !p.Grounded && p.State != TraversalDiving && p.RollTicks == 0 && w.tryGrabLedge(blocked, blockingBounds) {
		return blocked
	}

	previousBottom := position.Y + p.halfHeight()
	next.Y = position.Y + delta.Y
	p.Grounded = false
	for _, solid := range w.solidRects() {
		if !p.boundsAt(next).overlaps(solid) {
			continue
		}
		if delta.Y > 0 && previousBottom <= solid.Y+p.halfHeight() {
			next.Y = solid.Y - p.halfHeight()
			p.Grounded = true
			p.Velocity.Y = 0
		} else if delta.Y < 0 {
			next.Y = solid.Y + solid.H + p.halfHeight()
			p.Velocity.Y = 0
		}
	}
	if p.DropTicks == 0 && delta.Y >= 0 {
		for _, terrain := range w.Terrain {
			if terrain.Kind != TerrainPlatform || previousBottom > terrain.Bounds.Y+1 || !p.boundsAt(next).overlaps(terrain.Bounds) {
				continue
			}
			next.Y = terrain.Bounds.Y - p.halfHeight()
			p.Grounded, p.Velocity.Y = true, 0
		}
	}
	if next.Y > ArenaH+48 {
		w.Lost = true
	}
	p.Pos = next
	w.pushMovables(delta.X)
	return blocked
}

func (w *World) tryGrabLedge(direction int8, blockingBounds Rect) bool {
	p := &w.Player
	if p.Velocity.Y < 0 {
		return false
	}
	for _, terrain := range w.Terrain {
		// A ledge grab belongs to the terrain that stopped horizontal movement.
		// Selecting any terrain at a similar height can move the player to a
		// distant platform in the procedural arena.
		if !terrain.solid() || terrain.Bounds != blockingBounds || terrain.Bounds.Y >= p.Pos.Y || p.Pos.Y-terrain.Bounds.Y > 28 {
			continue
		}
		edge := terrain.Bounds.X
		if direction < 0 {
			edge = terrain.Bounds.X + terrain.Bounds.W
		}
		stand := Vec{X: edge - float64(direction)*(playerHalfW+2), Y: terrain.Bounds.Y - p.halfHeight()}
		hang := Vec{X: stand.X, Y: terrain.Bounds.Y + playerStandHalfH - 3}
		if !w.boundsBlocked(p.boundsAt(stand)) && !w.boundsBlocked(p.boundsAt(hang)) {
			p.Pos, p.Velocity = hang, Vec{}
			p.LedgeDirection, p.LedgeTarget, p.LedgeTicks = direction, stand, ledgeGrabTicks
			p.State, p.WallDirection, p.WallTicks = TraversalLedgeGrab, 0, 0
			return true
		}
	}
	return false
}

func (w *World) standingOnPlatform() bool {
	bottom := w.Player.Pos.Y + w.Player.halfHeight()
	for _, terrain := range w.Terrain {
		body := w.Player.boundsAt(w.Player.Pos)
		if terrain.Kind == TerrainPlatform && math.Abs(bottom-terrain.Bounds.Y) < 1.1 && body.X < terrain.Bounds.X+terrain.Bounds.W && body.X+body.W > terrain.Bounds.X {
			return true
		}
	}
	return false
}

func (w *World) solidRects() []Rect {
	rects := make([]Rect, 0, len(w.Terrain)+len(w.Objects))
	for _, terrain := range w.Terrain {
		if terrain.solid() {
			rects = append(rects, terrain.Bounds)
		}
	}
	for _, object := range w.Objects {
		if object.Kind == ObjectDoor && !object.Active {
			rects = append(rects, object.bounds())
		}
	}
	return rects
}

func (w *World) boundsBlocked(bounds Rect) bool {
	for _, solid := range w.solidRects() {
		if bounds.overlaps(solid) {
			return true
		}
	}
	return false
}

func (w *World) pushMovables(horizontal float64) {
	if horizontal == 0 || w.Player.HeldObjectID >= 0 {
		return
	}
	playerBounds := w.Player.boundsAt(w.Player.Pos)
	for index := range w.Objects {
		object := &w.Objects[index]
		if !object.movable() || object.Held || !playerBounds.overlaps(object.bounds()) {
			continue
		}
		next := object.Pos
		next.X += horizontal
		if !w.boundsBlocked(object.boundsAt(next)) {
			object.Pos = next
		}
	}
}

func (o WorldObject) boundsAt(pos Vec) Rect {
	return Rect{X: pos.X - o.Size.X/2, Y: pos.Y - o.Size.Y/2, W: o.Size.X, H: o.Size.Y}
}

func (w *World) climbInput(input InputFrame) bool {
	if w.objectByID(w.Player.ClimbObjectID) == nil {
		return false
	}
	return input.Jump || input.Down || input.MoveX == 0
}

func (w *World) nearClimbable(position Vec) *WorldObject {
	for index := range w.Objects {
		object := &w.Objects[index]
		if object.climbable() && math.Abs(object.Pos.X-position.X) <= 18 && math.Abs(object.Pos.Y-position.Y) <= object.Size.Y/2+20 {
			return object
		}
	}
	return nil
}

func (w *World) handleInteraction(input InputFrame) {
	if !input.Interact || w.prevInput.Interact {
		return
	}
	p := &w.Player
	if p.Tether.Active && w.activateSwitchAt(p.Tether.Pos) {
		return
	}
	if p.HeldObjectID >= 0 {
		w.dropHeldObject()
		return
	}
	for index := range w.Objects {
		object := &w.Objects[index]
		if object.Pos.Distance(p.Pos) > 28 {
			continue
		}
		switch object.Kind {
		case ObjectCrate, ObjectRock:
			object.Held, p.HeldObjectID = true, object.ID
			return
		case ObjectVineNode:
			w.activateVine(object)
			return
		case ObjectTeleporter:
			w.useTeleporter(object)
			return
		case ObjectSwitch:
			object.Active = true
			return
		}
	}
}

func (w *World) activateVine(node *WorldObject) {
	if node.Active {
		return
	}
	node.Active = true
	w.Objects = append(w.Objects, WorldObject{ID: w.nextObjectID(), Kind: ObjectVine, Pos: node.Pos.Add(Vec{Y: -78}), Size: Vec{X: 10, Y: 156}})
}

func (w *World) useTeleporter(source *WorldObject) {
	if source.Active {
		return
	}
	target := w.objectByID(source.LinkID)
	if target == nil {
		return
	}
	w.Player.Pos = target.Pos.Add(Vec{Y: -target.Size.Y/2 - w.Player.halfHeight()})
	w.Player.Velocity = Vec{}
	source.Active, target.Active = true, true
	w.Trauma = 0.22
}

func (w *World) dropHeldObject() {
	p := &w.Player
	object := w.objectByID(p.HeldObjectID)
	if object != nil {
		object.Held = false
		object.Pos = p.Pos.Add(Vec{X: float64(p.Facing) * 18, Y: -2})
	}
	p.HeldObjectID = -1
}

func (w *World) updateHeldObject() {
	p := &w.Player
	if p.HeldObjectID < 0 {
		return
	}
	object := w.objectByID(p.HeldObjectID)
	if object == nil {
		p.HeldObjectID = -1
		return
	}
	object.Pos = p.Pos.Add(Vec{X: float64(p.Facing) * 16, Y: -12})
}

func (w *World) handleObjectActions(input InputFrame) {
	if input.Throw && !w.prevInput.Throw {
		w.throwHeldObject()
	}
}

func (w *World) updateTether(input InputFrame) {
	p := &w.Player
	if !p.Tether.Active {
		return
	}
	step := p.Aim.Scale(4.2)
	candidate := p.Tether.Pos.Add(step)
	if candidate.Distance(p.Pos) > 142 {
		candidate = p.Pos.Add(candidate.Sub(p.Pos).Normalized().Scale(142))
	}
	probe := Rect{X: candidate.X - 2, Y: candidate.Y - 2, W: 4, H: 4}
	if !w.boundsBlocked(probe) {
		p.Tether.Pos = candidate
	}
}

func (w *World) throwHeldObject() {
	p := &w.Player
	object := w.objectByID(p.HeldObjectID)
	if object == nil {
		return
	}
	object.Held = false
	object.Vel = p.Aim.Scale(8.5).Add(Vec{Y: -1.2})
	p.HeldObjectID = -1
}

func (w *World) updateObjects() {
	live := w.Objects[:0]
	for index := range w.Objects {
		object := w.Objects[index]
		switch object.Kind {
		case ObjectCrate, ObjectRock:
			if !object.Held {
				object.Vel.Y = min(12, object.Vel.Y+Gravity)
				object.Pos = w.moveObject(object, object.Vel)
				object.Vel.X *= 0.75
			}
		}
		live = append(live, object)
	}
	w.Objects = live
}

func (w *World) collectTreasure() {
	if len(w.Run.Rooms) == 0 {
		return
	}
	playerBounds := w.Player.boundsAt(w.Player.Pos)
	live := w.Objects[:0]
	for _, object := range w.Objects {
		if object.Kind == ObjectTreasure && playerBounds.overlaps(object.bounds()) {
			w.Stats.Treasure++
			w.Trauma = max(w.Trauma, .08)
			continue
		}
		live = append(live, object)
	}
	w.Objects = live
}

func (w *World) updateRunStats() {
	if len(w.Run.Rooms) == 0 {
		return
	}
	room := int(w.Player.Pos.X/RoomW) + 1
	if room > w.Stats.RoomsReached {
		w.Stats.RoomsReached = min(room, len(w.Run.Rooms))
	}
}

func (w *World) moveObject(object WorldObject, delta Vec) Vec {
	next := object.Pos.Add(delta)
	for _, solid := range w.solidRects() {
		if !object.boundsAt(next).overlaps(solid) {
			continue
		}
		if delta.X > 0 {
			next.X = solid.X - object.Size.X/2
		} else if delta.X < 0 {
			next.X = solid.X + solid.W + object.Size.X/2
		}
		if delta.Y > 0 {
			next.Y = solid.Y - object.Size.Y/2
			object.Vel.Y = 0
		} else if delta.Y < 0 {
			next.Y = solid.Y + solid.H + object.Size.Y/2
			object.Vel.Y = 0
		}
	}
	return next
}

func (w *World) breakFloorBelow(fallSpeed float64) bool {
	p := &w.Player
	for index := range w.Terrain {
		terrain := &w.Terrain[index]
		if terrain.Kind == TerrainBreakable && terrain.HP > 0 && p.Pos.X >= terrain.Bounds.X && p.Pos.X <= terrain.Bounds.X+terrain.Bounds.W && p.Pos.Y+p.halfHeight() <= terrain.Bounds.Y+18 && fallSpeed > 5 {
			terrain.HP = 0
			w.Trauma = 0.2
			return true
		}
	}
	return false
}

func (w *World) updateLinks() {
	for index := range w.Objects {
		object := &w.Objects[index]
		if object.Kind == ObjectPlate {
			object.Active = false
			plateBounds := object.bounds()
			for _, other := range w.Objects {
				if other.movable() && !other.Held && other.bounds().overlaps(plateBounds) {
					object.Active = true
				}
			}
		}
	}
	for index := range w.Objects {
		object := &w.Objects[index]
		if object.Kind != ObjectDoor {
			continue
		}
		link := w.objectByID(object.LinkID)
		object.Active = link != nil && link.Active
	}
}

func (w *World) activateSwitchAt(position Vec) bool {
	for index := range w.Objects {
		object := &w.Objects[index]
		if object.Kind == ObjectSwitch && object.Pos.Distance(position) < 18 {
			object.Active = true
			return true
		}
	}
	return false
}

func (w *World) applyHazards() {
	bounds := w.Player.boundsAt(w.Player.Pos)
	for _, terrain := range w.Terrain {
		if (terrain.Kind == TerrainWater || terrain.Kind == TerrainSpike || terrain.Kind == TerrainPit) && bounds.overlaps(terrain.Bounds) {
			w.Lost = true
			w.Trauma = 0.36
			return
		}
	}
}

func (w *World) checkExit() {
	for _, object := range w.Objects {
		if object.Kind == ObjectExit && w.Player.boundsAt(w.Player.Pos).overlaps(object.bounds()) {
			w.Won = true
			return
		}
	}
}

func (w *World) objectByID(id int) *WorldObject {
	for index := range w.Objects {
		if w.Objects[index].ID == id {
			return &w.Objects[index]
		}
	}
	return nil
}

func (w *World) StateHash() uint64 {
	h := fnv.New64a()
	q := func(value float64) int64 { return int64(math.Round(value * 1000)) }
	p := w.Player
	_, _ = fmt.Fprintf(h, "%s/%s/seed%d/t%d/w%d/l%d/stats%d,%d,%d,%d,%d/p%d,%d/%d,%d/f%d/gr%d/st%d/c%d/j%d/a%d/wall%d/%d/roll%d/%d/crouch%d/drop%d/ledge%d/%d/%d,%d/m%d/cl%d/held%d/te%d/%d,%d", SimulationVersion, RunVersion, w.Seed, w.Tick, boolHash(w.Won), boolHash(w.Lost), w.Stats.RoomsReached, w.Stats.Treasure, w.Stats.EnemiesDefeated, w.Stats.ObjectsThrown, w.Stats.TerrainBroken, q(p.Pos.X), q(p.Pos.Y), q(p.Velocity.X), q(p.Velocity.Y), p.Facing, boolHash(p.Grounded), p.State, p.Coyote, p.JumpBuffer, p.AirJumps, p.WallDirection, p.WallTicks, p.RollTicks, p.RollCooldown, boolHash(p.Crouching), p.DropTicks, p.LedgeTicks, p.LedgeDirection, q(p.LedgeTarget.X), q(p.LedgeTarget.Y), p.MantleTicks, p.ClimbObjectID, p.HeldObjectID, boolHash(p.Tether.Active), q(p.Tether.Pos.X), q(p.Tether.Pos.Y))
	for _, terrain := range w.Terrain {
		_, _ = fmt.Fprintf(h, "/t%d/%d/%d/%d,%d,%d,%d", terrain.ID, terrain.Kind, terrain.HP, q(terrain.Bounds.X), q(terrain.Bounds.Y), q(terrain.Bounds.W), q(terrain.Bounds.H))
	}
	for _, object := range w.Objects {
		_, _ = fmt.Fprintf(h, "/o%d/%d/%d,%d/%d,%d/%d,%d/l%d/a%d/h%d", object.ID, object.Kind, q(object.Pos.X), q(object.Pos.Y), q(object.Vel.X), q(object.Vel.Y), q(object.Size.X), q(object.Size.Y), object.LinkID, boolHash(object.Active), boolHash(object.Held))
	}
	return h.Sum64()
}

func boolHash(value bool) int {
	if value {
		return 1
	}
	return 0
}
