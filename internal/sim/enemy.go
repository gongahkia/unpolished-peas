package sim

import "math"

type EnemyState uint8

const (
	EnemyRoam EnemyState = iota
	EnemyTelegraph
	EnemyCharge
	EnemyRecover
	EnemyDive
	EnemyStunned
)

func (s EnemyState) String() string {
	switch s {
	case EnemyTelegraph:
		return "telegraph"
	case EnemyCharge:
		return "charge"
	case EnemyRecover:
		return "recover"
	case EnemyDive:
		return "dive"
	case EnemyStunned:
		return "stunned"
	default:
		return "roam"
	}
}

type Enemy struct {
	ID        int
	Archetype EnemyArchetype
	State     EnemyState
	Pos, Vel  Vec
	Size      Vec
	Facing    int8
	Grounded  bool
	Timer     int
	Flash     int
	Dead      bool
}

func (e Enemy) bounds() Rect { return e.boundsAt(e.Pos) }

func (e Enemy) boundsAt(position Vec) Rect {
	return Rect{X: position.X - e.Size.X/2, Y: position.Y - e.Size.Y/2, W: e.Size.X, H: e.Size.Y}
}

func newEnemy(id int, spawn EnemySpawn) Enemy {
	enemy := Enemy{ID: id, Archetype: spawn.Archetype, Pos: spawn.Pos, Facing: -1, State: EnemyRoam}
	switch spawn.Archetype {
	case EnemyHopper:
		enemy.Size, enemy.Timer = Vec{X: 18, Y: 20}, 42
	case EnemyDiver:
		enemy.Size, enemy.Timer = Vec{X: 20, Y: 18}, 30
	default:
		enemy.Size, enemy.Timer = Vec{X: 22, Y: 24}, 28
	}
	return enemy
}

func (w *World) updateEnemies() {
	for index := range w.Enemies {
		enemy := &w.Enemies[index]
		if enemy.Dead {
			continue
		}
		if enemy.Flash > 0 {
			enemy.Flash--
		}
		switch enemy.Archetype {
		case EnemyHopper:
			w.updateHopper(enemy)
		case EnemyDiver:
			w.updateDiver(enemy)
		default:
			w.updateCharger(enemy)
		}
	}
	w.resolvePlayerEnemyContacts()
	w.removeDeadEnemies()
}

func (w *World) updateCharger(enemy *Enemy) {
	if enemy.Timer > 0 {
		enemy.Timer--
	}
	switch enemy.State {
	case EnemyRoam:
		if math.Abs(w.Player.Pos.X-enemy.Pos.X) < 230 && math.Abs(w.Player.Pos.Y-enemy.Pos.Y) < 60 {
			enemy.Facing = directionToward(enemy.Pos.X, w.Player.Pos.X, enemy.Facing)
			enemy.State, enemy.Timer, enemy.Vel = EnemyTelegraph, 24, Vec{}
			return
		}
		enemy.Vel.X = float64(enemy.Facing) * .55
	case EnemyTelegraph:
		if enemy.Timer == 0 {
			enemy.State, enemy.Timer, enemy.Vel.X = EnemyCharge, 42, float64(enemy.Facing)*7.2
		}
	case EnemyCharge:
		enemy.Vel.X = float64(enemy.Facing) * 7.2
		if enemy.Timer == 0 {
			enemy.State, enemy.Timer, enemy.Vel.X = EnemyRecover, 20, 0
		}
	case EnemyRecover, EnemyStunned:
		enemy.Vel.X *= .6
		if enemy.Timer == 0 {
			enemy.State, enemy.Timer = EnemyRoam, 20
		}
	}
	enemy.Vel.Y = min(13, enemy.Vel.Y+Gravity)
	wall, blocked := w.moveEnemy(enemy, enemy.Vel)
	if enemy.State == EnemyCharge {
		if blocked {
			w.breakTerrainAgainst(enemy.bounds(), 6)
			enemy.State, enemy.Timer, enemy.Vel = EnemyRecover, 24, Vec{}
			w.Trauma = max(w.Trauma, .18)
		}
		w.chargerHitsActors(enemy)
		if wall != 0 {
			enemy.Facing = -wall
		}
	}
}

func (w *World) updateHopper(enemy *Enemy) {
	if enemy.Timer > 0 {
		enemy.Timer--
	}
	if enemy.Grounded && enemy.Timer == 0 {
		enemy.Facing = directionToward(enemy.Pos.X, w.Player.Pos.X, enemy.Facing)
		enemy.Vel = Vec{X: float64(enemy.Facing) * 2.7, Y: -8.5}
		enemy.Timer = 52
	}
	enemy.Vel.Y = min(13, enemy.Vel.Y+Gravity)
	wall, _ := w.moveEnemy(enemy, enemy.Vel)
	if wall != 0 {
		enemy.Facing = -wall
	}
}

func (w *World) updateDiver(enemy *Enemy) {
	if enemy.Timer > 0 {
		enemy.Timer--
	}
	switch enemy.State {
	case EnemyRoam:
		if enemy.Timer == 0 && enemy.Pos.Distance(w.Player.Pos) < 330 {
			enemy.Facing = directionToward(enemy.Pos.X, w.Player.Pos.X, enemy.Facing)
			enemy.State, enemy.Timer = EnemyTelegraph, 28
		}
	case EnemyTelegraph:
		if enemy.Timer == 0 {
			direction := w.Player.Pos.Sub(enemy.Pos).Normalized()
			if direction.LengthSq() == 0 {
				direction = Vec{X: float64(enemy.Facing)}
			}
			enemy.State, enemy.Timer, enemy.Vel = EnemyDive, 36, direction.Scale(6.4)
		}
	case EnemyDive:
		_, blocked := w.moveEnemy(enemy, enemy.Vel)
		if blocked || enemy.Timer == 0 {
			enemy.State, enemy.Timer, enemy.Vel = EnemyStunned, 34, Vec{}
			w.Trauma = max(w.Trauma, .12)
		}
	case EnemyStunned:
		if enemy.Timer == 0 {
			enemy.State, enemy.Timer = EnemyRoam, 34
		}
	}
}

func directionToward(from, to float64, fallback int8) int8 {
	if to > from {
		return 1
	}
	if to < from {
		return -1
	}
	return fallback
}

func (w *World) moveEnemy(enemy *Enemy, delta Vec) (int8, bool) {
	next := enemy.Pos
	wall, blocked := int8(0), false
	next.X = clamp(enemy.Pos.X+delta.X, enemy.Size.X/2, ArenaW-enemy.Size.X/2)
	for index := range w.Terrain {
		terrain := &w.Terrain[index]
		if !terrain.solid() || !enemy.boundsAt(next).overlaps(terrain.Bounds) {
			continue
		}
		if enemy.Archetype == EnemyCharger && enemy.State == EnemyCharge && terrain.Kind == TerrainBreakable && delta.X != 0 {
			w.destroyBreakable(index, .24)
			continue
		}
		if delta.X > 0 {
			next.X, wall = terrain.Bounds.X-enemy.Size.X/2, 1
		} else if delta.X < 0 {
			next.X, wall = terrain.Bounds.X+terrain.Bounds.W+enemy.Size.X/2, -1
		}
		blocked = true
		enemy.Vel.X = 0
	}
	for index := range w.Objects {
		object := &w.Objects[index]
		if object.Kind != ObjectDoor || object.Active || !enemy.boundsAt(next).overlaps(object.bounds()) {
			continue
		}
		if delta.X > 0 {
			next.X, wall = object.bounds().X-enemy.Size.X/2, 1
		} else if delta.X < 0 {
			next.X, wall = object.bounds().X+object.bounds().W+enemy.Size.X/2, -1
		}
		blocked = true
		enemy.Vel.X = 0
	}

	previousBottom := enemy.Pos.Y + enemy.Size.Y/2
	next.Y = enemy.Pos.Y + delta.Y
	enemy.Grounded = false
	for _, solid := range w.solidRects() {
		if !enemy.boundsAt(next).overlaps(solid) {
			continue
		}
		if delta.Y > 0 && previousBottom <= solid.Y+enemy.Size.Y/2 {
			next.Y, enemy.Grounded, enemy.Vel.Y = solid.Y-enemy.Size.Y/2, true, 0
		} else if delta.Y < 0 {
			next.Y, enemy.Vel.Y = solid.Y+solid.H+enemy.Size.Y/2, 0
		}
	}
	enemy.Pos = next
	return wall, blocked
}

func (w *World) chargerHitsActors(charger *Enemy) {
	for index := range w.Objects {
		object := &w.Objects[index]
		if !object.movable() || object.Held || !charger.bounds().overlaps(object.bounds()) {
			continue
		}
		object.Vel = Vec{X: float64(charger.Facing) * 9, Y: -2.8}
		charger.State, charger.Timer, charger.Vel = EnemyRecover, 16, Vec{}
		w.Trauma = max(w.Trauma, .2)
		return
	}
	for index := range w.Enemies {
		other := &w.Enemies[index]
		if other.ID == charger.ID || other.Dead || !charger.bounds().overlaps(other.bounds()) {
			continue
		}
		w.defeatEnemy(other)
		charger.State, charger.Timer, charger.Vel = EnemyRecover, 16, Vec{}
		w.Trauma = max(w.Trauma, .24)
		return
	}
}

func (w *World) resolvePlayerEnemyContacts() {
	playerBounds := w.Player.boundsAt(w.Player.Pos)
	for index := range w.Enemies {
		enemy := &w.Enemies[index]
		if enemy.Dead || !playerBounds.overlaps(enemy.bounds()) {
			continue
		}
		if w.Player.Velocity.Y > 3 && w.Player.Pos.Y < enemy.Pos.Y {
			w.defeatEnemy(enemy)
			w.Player.Velocity.Y = -7.6
			w.Player.Grounded = false
			w.Trauma = max(w.Trauma, .2)
			continue
		}
		w.Lost = true
		w.Trauma = max(w.Trauma, .34)
		return
	}
}

func (w *World) defeatEnemy(enemy *Enemy) {
	if enemy.Dead {
		return
	}
	enemy.Dead, enemy.Flash = true, 8
	w.Stats.EnemiesDefeated++
	w.punctuate(enemy.Pos, .2, 2)
}

func (w *World) removeDeadEnemies() {
	live := w.Enemies[:0]
	for _, enemy := range w.Enemies {
		if !enemy.Dead {
			live = append(live, enemy)
		}
	}
	w.Enemies = live
}
