package sim

import (
	"fmt"
	"hash"
	"hash/fnv"
	"math"
	"sort"
)

const SimulationVersion = "72-platform-1"

// World is the renderer-independent, deterministic 72 arena simulation.
type World struct {
	Seed, Tick, RNG uint64
	Player          Player
	Enemies         []*Enemy
	Clones          []*Clone
	Projectiles     []*Projectile
	Effects         []Effect
	Terrain         []Terrain
	Hitstop         int
	SlowTicks       int
	Trauma          float64
	TraumaDirection Vec
	Won, Lost       bool
	Debug           bool
	inputHistory    []InputFrame
	nextID          int
	prevInput       InputFrame
}

func NewWorld(seed uint64) *World {
	if seed == 0 {
		seed = 1
	}
	return &World{Seed: seed, RNG: seed, Player: newPlayer(), nextID: 1}
}

// NewValidationWorld creates the single fast-restart combat-design encounter.
func NewValidationWorld(seed uint64) *World {
	w := NewWorld(seed)
	w.Terrain = validationTerrain()
	w.Player.Pos = Vec{X: 150, Y: 500}
	w.SpawnArenaBoss(Vec{X: 1060, Y: 319})
	return w
}

func (w *World) ResetEncounter() { *w = *NewValidationWorld(w.Seed) }

func (w *World) nextEntityID() int { id := w.nextID; w.nextID++; return id }

func (w *World) Random() uint64 {
	w.RNG ^= w.RNG << 13
	w.RNG ^= w.RNG >> 7
	w.RNG ^= w.RNG << 17
	return w.RNG
}

func (w *World) SpawnArenaBoss(position Vec) *Enemy {
	e := &Enemy{ID: w.nextEntityID(), Kind: EnemyBoss, Name: "warden", Pos: position, Facing: Vec{X: -1}, Radius: 21, HP: 520, MaxHP: 520, Damage: 18, MoveSpeed: 1.05, AttackRange: 42, TargetCloneID: -1, Boss: newArenaBoss()}
	w.Enemies = append(w.Enemies, e)
	return e
}

func (w *World) Step(input InputFrame) {
	if w.Lost && input.Restart && !w.prevInput.Restart {
		w.ResetEncounter()
		return
	}
	w.Tick++
	w.recordInput(input)
	if input.Staff != StaffNone {
		w.Player.Staff = input.Staff
	}
	if input.DebugStep && !w.prevInput.DebugStep {
		w.Debug = !w.Debug
	}
	w.updateEffects()
	w.Trauma *= 0.87
	if w.Hitstop > 0 {
		w.Hitstop--
		w.prevInput = input
		return
	}
	if w.SlowTicks > 0 {
		w.SlowTicks--
		if w.Tick%2 == 1 {
			w.prevInput = input
			return
		}
	}
	w.handleInput(input)
	w.updatePlayer(input)
	w.updateClones()
	w.updateEnemies()
	w.updateProjectiles()
	w.resolveBodyCollisions()
	w.removeDead()
	w.prevInput = input
}

func (w *World) recordInput(input InputFrame) {
	w.inputHistory = append(w.inputHistory, input)
	if len(w.inputHistory) > 150 {
		copy(w.inputHistory, w.inputHistory[len(w.inputHistory)-150:])
		w.inputHistory = w.inputHistory[:150]
	}
}

func (w *World) handleInput(input InputFrame) {
	p := &w.Player
	aim := Vec{X: float64(input.AimX), Y: float64(input.AimY)}
	if aim.LengthSq() > 1 {
		aim = aim.Normalized()
	}
	if aim.LengthSq() > 0 {
		p.Aim = aim
	}
	if input.Transform != FormNone && input.Transform != p.Form && p.TransformCooldown == 0 {
		wasBird := p.Form == FormBird
		p.Form = input.Transform
		p.TransformCooldown = 12
		if wasBird && p.Form != FormBird {
			p.BirdMomentum = 12
		} else if !wasBird {
			p.Velocity.X = 0
		}
		w.Effects = append(w.Effects, Effect{Kind: EffectTransform, Pos: p.Pos, Radius: 24, TicksRemaining: 14, Intensity: 0.5})
		w.addTrauma(0.16)
	}
	if input.Clone && !w.prevInput.Clone {
		w.SpawnEcho()
	}
	if input.Dodge && !w.prevInput.Dodge && p.DodgeCooldown == 0 && p.Form != FormTiger && p.Action != ActionMantisStance {
		w.startDodge(input)
	}
	if input.Jump && !w.prevInput.Jump && (p.Grounded || p.Form == FormBird) && p.Action != ActionTigerPounce {
		jump := JumpSpeed
		if p.Form == FormBird {
			jump = 7.4
		}
		p.Velocity.Y = -jump
		p.Grounded = false
		w.Effects = append(w.Effects, Effect{Kind: EffectAfterimage, Pos: p.Pos, Direction: Vec{Y: -1}, Radius: 10, TicksRemaining: 5, Intensity: 0.18})
	}
	if input.Attack && !w.prevInput.Attack {
		p.AttackBuffer = 7
		if p.Action == ActionIdle {
			w.startPlayerAction()
		}
	}
	if p.Action == ActionLongCharge && !input.Attack {
		w.releaseLong(nil)
	}
}

func (w *World) startPlayerAction() {
	p := &w.Player
	p.AttackBuffer = 0
	p.ActionTick = 0
	p.AttackHitIDs = make(map[int]bool)
	switch p.Form {
	case FormBird:
		p.Action, p.Velocity = ActionBirdDive, p.Aim.Scale(8.4)
	case FormTiger:
		p.Action, p.Velocity = ActionTigerPounce, p.Aim.Scale(9.2)
	case FormMantis:
		p.Action, p.CounterWindow = ActionMantisStance, 10
	default:
		switch p.Staff {
		case StaffShort:
			p.Action, p.LastAttackSpec = ActionShort, shortSpec()
		case StaffLong:
			p.Action, p.LongCharge, p.LongRange = ActionLongCharge, 0, 28
			w.Effects = append(w.Effects, Effect{Kind: EffectCharge, Pos: p.Pos, Direction: p.Aim, Radius: p.LongRange, TicksRemaining: 3})
		default:
			p.Action, p.LastAttackSpec = ActionMedium, mediumSpec(p.Combo)
		}
	}
}

func (w *World) startDodge(input InputFrame) {
	p := &w.Player
	direction := float64(input.MoveX)
	if direction == 0 {
		direction = p.Aim.X
	}
	if direction == 0 {
		direction = 1
	}
	p.Action, p.ActionTick, p.DodgeCooldown, p.Invulnerable = ActionDodge, 0, 28, 8
	p.Velocity.X = direction * 8.0
	w.Effects = append(w.Effects, Effect{Kind: EffectAfterimage, Pos: p.Pos, Direction: Vec{X: direction}, Radius: 14, TicksRemaining: 8, Intensity: 0.25})
}

func (w *World) updatePlayer(input InputFrame) {
	p := &w.Player
	decrement(&p.DodgeCooldown)
	decrement(&p.Invulnerable)
	decrement(&p.TransformCooldown)
	decrement(&p.CloneCooldown)
	if p.Action == ActionDead {
		return
	}
	if p.Stagger > 0 {
		p.Stagger--
		w.movePlayerPhysics(p.Velocity.X)
		p.Velocity.X *= 0.76
		return
	}
	moveX := float64(input.MoveX)
	switch p.Action {
	case ActionDodge:
		w.movePlayerPhysics(p.Velocity.X)
		p.ActionTick++
		if p.ActionTick >= 9 {
			p.Action, p.Velocity.X = ActionIdle, 0
		}
		return
	case ActionLongCharge:
		p.LongCharge = min(48, p.LongCharge+1)
		p.LongRange = 28 + float64(p.LongCharge)*2.25
		w.movePlayerPhysics(moveX * rulesFor(p.Form).MoveSpeed * 0.32)
		w.Effects = append(w.Effects, Effect{Kind: EffectCharge, Pos: p.Pos, Direction: p.Aim, Radius: p.LongRange, TicksRemaining: 2, Intensity: float64(p.LongCharge) / 48})
		return
	case ActionBirdDive:
		w.movePlayerDirect(p.Velocity)
		if p.ActionTick >= 3 && p.ActionTick < 9 {
			w.resolveAttack(p.Pos, p.Aim, AttackSpec{Range: 18, Width: 18, Damage: 15, Knockback: 7, Heavy: true}, p.AttackHitIDs, false, p.Form)
		}
		p.ActionTick++
		if p.ActionTick >= 14 {
			p.Action = ActionIdle
			p.Velocity = p.Velocity.Scale(0.45)
		}
		return
	case ActionTigerPounce:
		start := p.Pos
		w.breakTerrainAlong(start, start.Add(p.Velocity))
		w.movePlayerDirect(p.Velocity)
		if p.ActionTick >= 2 && p.ActionTick < 12 {
			w.resolveAttack(p.Pos, p.Aim, AttackSpec{Range: 22, Width: 18, Damage: 25, Knockback: 12, Heavy: true}, p.AttackHitIDs, false, p.Form)
		}
		p.ActionTick++
		if p.ActionTick >= 16 {
			p.Action = ActionIdle
			p.Velocity = Vec{}
		}
		return
	case ActionMantisStance:
		w.movePlayerPhysics(0)
		p.CounterWindow--
		p.ActionTick++
		if p.CounterWindow <= 0 {
			p.Action = ActionIdle
		}
		return
	}
	speed := rulesFor(p.Form).MoveSpeed
	if p.BirdMomentum > 0 && p.Form != FormBird {
		moveX += p.Velocity.X
		p.Velocity.X *= 0.84
		p.BirdMomentum--
	}
	if p.Action == ActionShort {
		speed *= 0.95
	}
	if p.Action == ActionMedium {
		speed *= 0.45
	}
	w.movePlayerPhysics(moveX * speed)
	if p.Form == FormBird {
		// Bird flight keeps horizontal momentum when returning to Monkey form.
		p.Velocity.X = moveX * speed
	}
	if p.Action == ActionIdle && p.AttackBuffer > 0 {
		w.startPlayerAction()
	}
	if p.Action == ActionShort || p.Action == ActionMedium || p.Action == ActionLongRelease {
		if p.actionActive() {
			w.resolveAttack(p.Pos, p.Aim, p.LastAttackSpec, p.AttackHitIDs, false, p.Form)
		}
		p.ActionTick++
		if p.ActionTick >= p.LastAttackSpec.Total() {
			if p.Action == ActionMedium && p.Combo < 2 {
				p.Combo++
			} else {
				p.Combo = 0
			}
			p.Action = ActionIdle
		}
	}
	if p.Action != ActionIdle {
		decrement(&p.AttackBuffer)
	}
}

func (w *World) releaseLong(clone *Clone) {
	p := &w.Player
	charge := p.LongCharge
	if clone != nil {
		charge = clone.LongCharge
	}
	spec := AttackSpec{Startup: 2, Active: 5, Recovery: 24, Range: 28 + float64(charge)*2.25, Width: 13 + float64(charge)/7, Damage: 18 + charge/3, Knockback: 10 + float64(charge)/8, Heavy: charge >= 24}
	if clone != nil {
		clone.Action, clone.ActionTick, clone.AttackSpec, clone.HitIDs = ActionLongRelease, 0, spec, make(map[int]bool)
		return
	}
	p.Action, p.ActionTick, p.LastAttackSpec, p.AttackHitIDs = ActionLongRelease, 0, spec, make(map[int]bool)
	if charge >= 24 {
		w.addTrauma(0.18)
	}
}

func (w *World) SpawnEcho() {
	p := &w.Player
	if p.CloneCooldown > 0 || p.Action == ActionDead || len(w.inputHistory) < 20 {
		return
	}
	frames := append([]InputFrame(nil), w.inputHistory[max(0, len(w.inputHistory)-120):]...)
	position := clampArena(p.Pos.Sub(p.Aim.Scale(24)), 7)
	w.Clones = append(w.Clones, &Clone{ID: w.nextEntityID(), Pos: position, Aim: p.Aim, Radius: rulesFor(FormMonkey).Radius, Form: FormMonkey, Grounded: p.Grounded, Delay: 20, EchoIndex: -20, Frames: frames, Staff: p.Staff, HitIDs: make(map[int]bool), TicksRemaining: len(frames) + 20})
	p.CloneCooldown = 150
	w.Effects = append(w.Effects, Effect{Kind: EffectTransform, Pos: position, Radius: 22, TicksRemaining: 16, Intensity: 0.6})
}

func (w *World) updateClones() {
	live := w.Clones[:0]
	for _, c := range w.Clones {
		c.TicksRemaining--
		c.EchoIndex++
		if c.EchoIndex >= 0 && c.EchoIndex < len(c.Frames) {
			w.stepEcho(c, c.Frames[c.EchoIndex])
		}
		if c.TicksRemaining > 0 {
			live = append(live, c)
		} else {
			w.Effects = append(w.Effects, Effect{Kind: EffectTransform, Pos: c.Pos, Radius: 18, TicksRemaining: 10, Intensity: 0.35})
		}
	}
	w.Clones = live
}

func (w *World) stepEcho(c *Clone, input InputFrame) {
	if input.Staff != StaffNone {
		c.Staff = input.Staff
	}
	aim := Vec{X: float64(input.AimX), Y: float64(input.AimY)}
	if aim.LengthSq() > 0 {
		c.Aim = aim.Normalized()
	}
	if input.Transform != FormNone && input.Transform != c.Form {
		c.Form = input.Transform
		c.Radius = rulesFor(c.Form).Radius
	}
	if input.Jump && !c.Previous.Jump && (c.Grounded || c.Form == FormBird) && c.Action != ActionTigerPounce {
		jump := JumpSpeed
		if c.Form == FormBird {
			jump = 7.4
		}
		c.Velocity.Y, c.Grounded = -jump, false
	}
	if c.Action != ActionBirdDive && c.Action != ActionTigerPounce && c.Action != ActionMantisStance {
		w.moveEchoPhysics(c, float64(input.MoveX)*rulesFor(c.Form).MoveSpeed)
	}
	pressed := input.Attack && !c.Previous.Attack
	if pressed && c.Action == ActionIdle {
		c.ActionTick, c.HitIDs = 0, make(map[int]bool)
		if c.Form == FormBird {
			c.Action, c.Velocity = ActionBirdDive, c.Aim.Scale(7.4)
		} else if c.Form == FormTiger {
			c.Action, c.Velocity = ActionTigerPounce, c.Aim.Scale(8.2)
		} else if c.Form == FormMantis {
			c.Action, c.ActionTick = ActionMantisStance, 0
		} else if c.Staff == StaffLong {
			c.Action, c.LongCharge, c.LongRange = ActionLongCharge, 0, 28
		} else if c.Staff == StaffShort {
			c.Action, c.AttackSpec = ActionShort, shortSpec()
		} else {
			c.Action, c.AttackSpec = ActionMedium, mediumSpec(0)
		}
	}
	if c.Action == ActionLongCharge {
		c.LongCharge++
		c.LongRange = 28 + float64(c.LongCharge)*2.25
		if !input.Attack {
			w.releaseLong(c)
		}
	}
	if c.Action == ActionBirdDive {
		w.moveEchoDirect(c, c.Velocity)
		if c.ActionTick >= 3 && c.ActionTick < 9 {
			w.resolveAttack(c.Pos, c.Aim, AttackSpec{Range: 16, Width: 16, Damage: 10, Knockback: 6, Heavy: true}, c.HitIDs, true, c.Form)
		}
		c.ActionTick++
		if c.ActionTick >= 14 {
			c.Action = ActionIdle
		}
	}
	if c.Action == ActionTigerPounce {
		start := c.Pos
		w.breakTerrainAlong(start, start.Add(c.Velocity))
		w.moveEchoDirect(c, c.Velocity)
		if c.ActionTick >= 2 && c.ActionTick < 12 {
			w.resolveAttack(c.Pos, c.Aim, AttackSpec{Range: 20, Width: 16, Damage: 17, Knockback: 10, Heavy: true}, c.HitIDs, true, c.Form)
		}
		c.ActionTick++
		if c.ActionTick >= 16 {
			c.Action = ActionIdle
		}
	}
	if c.Action == ActionMantisStance {
		w.moveEchoPhysics(c, 0)
		c.ActionTick++
		if c.ActionTick >= 10 {
			c.Action = ActionIdle
		}
	}
	if c.Action == ActionShort || c.Action == ActionMedium || c.Action == ActionLongRelease {
		if c.ActionTick >= c.AttackSpec.Startup && c.ActionTick < c.AttackSpec.Startup+c.AttackSpec.Active {
			w.resolveAttack(c.Pos, c.Aim, c.AttackSpec, c.HitIDs, true, c.Form)
		}
		c.ActionTick++
		if c.ActionTick >= c.AttackSpec.Total() {
			c.Action = ActionIdle
		}
	}
	c.Previous = input
}

func (w *World) resolveAttack(origin, aim Vec, spec AttackSpec, hitIDs map[int]bool, fromEcho bool, attackerForm FormID) {
	start, end := origin.Add(aim.Scale(5)), origin.Add(aim.Scale(spec.Range))
	if blocked, at := w.firstTerrainBlock(start, end); blocked {
		end = at
	}
	w.Effects = append(w.Effects, Effect{Kind: EffectStaffTrail, Pos: origin, Direction: aim, Radius: start.Distance(end), TicksRemaining: 4, Intensity: map[bool]float64{true: 0.85, false: 0.3}[spec.Heavy]})
	for _, projectile := range w.Projectiles {
		if !projectile.FromEnemy || projectile.TicksRemaining <= 0 || projectile.Pos.Distance(nearestPointOnSegment(projectile.Pos, start, end)) > spec.Width+projectile.Radius {
			continue
		}
		projectile.TicksRemaining = 0
		w.Effects = append(w.Effects, Effect{Kind: EffectImpact, Pos: projectile.Pos, Direction: aim, Radius: 8, TicksRemaining: 5, Intensity: 0.2})
	}
	for _, enemy := range w.Enemies {
		if !enemy.alive() || hitIDs[enemy.ID] || enemy.Invulnerable > 0 {
			continue
		}
		if enemy.Pos.Distance(nearestPointOnSegment(enemy.Pos, start, end)) > spec.Width+enemy.Radius {
			continue
		}
		if enemy.Boss != nil && !w.tryOpenBoss(enemy, fromEcho) {
			continue
		}
		damage := spec.Damage
		if fromEcho {
			damage = max(1, damage*2/3)
		}
		if enemy.WeakPoint > 0 {
			damage *= 2
		}
		if enemy.Armor > 0 {
			if attackerForm == FormTiger || spec.Heavy {
				enemy.Armor = 0
				enemy.Stagger = max(enemy.Stagger, 32)
				w.heavyFeedback(enemy.Pos, aim)
			} else {
				damage = max(1, damage-enemy.Armor)
			}
		}
		enemy.HP -= damage
		enemy.Flash = 5
		enemy.Velocity = enemy.Velocity.Add(aim.Scale(spec.Knockback))
		enemy.Stagger = max(enemy.Stagger, 5)
		hitIDs[enemy.ID] = true
		if spec.Heavy {
			w.heavyFeedback(enemy.Pos, aim)
		} else {
			w.hitFeedback(enemy.Pos, aim)
		}
	}
}

func (w *World) updateEnemies() {
	for _, enemy := range w.Enemies {
		if !enemy.alive() {
			continue
		}
		decrement(&enemy.Flash)
		decrement(&enemy.Invulnerable)
		decrement(&enemy.WeakPoint)
		if enemy.Boss != nil {
			w.updateBoss(enemy)
		}
		if enemy.Stagger > 0 {
			enemy.Stagger--
			w.moveEnemyPhysics(enemy, enemy.Velocity.X)
			enemy.Velocity.X *= 0.75
			continue
		}
		target, clone := w.enemyTarget(enemy)
		toTarget := target.Sub(enemy.Pos)
		if toTarget.LengthSq() > 0 {
			enemy.Facing = Vec{X: math.Copysign(1, toTarget.X)}
		}
		if enemy.Windup > 0 {
			enemy.AIState = "windup"
			enemy.Windup--
			w.moveEnemyPhysics(enemy, 0)
			if enemy.Windup == 0 {
				w.enemyAttack(enemy, target, clone)
			}
			continue
		}
		decrement(&enemy.AttackCooldown)
		if math.Abs(toTarget.X) <= enemy.AttackRange && math.Abs(toTarget.Y) <= 46 && enemy.AttackCooldown == 0 {
			enemy.AIState, enemy.Windup = "telegraph", 18
			w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: target, Radius: enemy.AttackRange, TicksRemaining: 18})
			continue
		}
		if enemy.Boss != nil && math.Abs(toTarget.X) > 175 {
			enemy.AIState = "guard"
			w.moveEnemyPhysics(enemy, 0)
			continue
		}
		enemy.AIState = "chase"
		if enemy.Grounded && target.Y+48 < enemy.Pos.Y {
			enemy.Velocity.Y = -8.2
			enemy.Grounded = false
		}
		w.moveEnemyPhysics(enemy, enemy.Facing.X*enemy.MoveSpeed)
	}
}

func (w *World) enemyTarget(enemy *Enemy) (Vec, *Clone) {
	for _, clone := range w.Clones {
		if enemy.Pos.Distance(clone.Pos) < enemy.Pos.Distance(w.Player.Pos)*1.25 {
			enemy.TargetCloneID = clone.ID
			return clone.Pos, clone
		}
	}
	enemy.TargetCloneID = -1
	return w.Player.Pos, nil
}

func (w *World) enemyAttack(enemy *Enemy, target Vec, clone *Clone) {
	enemy.AttackCooldown = 46
	if clone != nil {
		clone.TicksRemaining = 0
		return
	}
	if w.counterEnemyAttack(enemy) {
		return
	}
	w.damagePlayer(enemy.Damage, enemy.Facing.Scale(6), false)
}

// counterEnemyAttack centralizes the exceptional timing rules so every melee
// threat, including authored boss sweeps, is readable through the same verbs.
func (w *World) counterEnemyAttack(enemy *Enemy) bool {
	p := &w.Player
	if p.Form == FormMantis && p.Action == ActionMantisStance && p.CounterWindow > 0 {
		enemy.Stagger, enemy.WeakPoint, enemy.Velocity = 72, 180, enemy.Facing.Scale(-13)
		if enemy.Boss != nil {
			enemy.Boss.Shielded = false
			enemy.Boss.VulnerableTicks = 180
			enemy.Boss.Telegraph = "weak point exposed"
		}
		w.Hitstop, w.SlowTicks = max(w.Hitstop, 8), 10
		w.addTrauma(1)
		w.Effects = append(w.Effects, Effect{Kind: EffectHeavyImpact, Pos: p.Pos, Radius: 48, TicksRemaining: 20, Intensity: 1})
		return true
	}
	if p.Form == FormMonkey && p.Staff == StaffShort && p.Action == ActionShort && p.ActionTick >= 2 && p.ActionTick < 5 {
		enemy.Stagger, enemy.Velocity = 32, enemy.Facing.Scale(-8)
		w.Hitstop = max(w.Hitstop, 4)
		w.addTrauma(0.45)
		w.Effects = append(w.Effects, Effect{Kind: EffectCounter, Pos: p.Pos, Radius: 27, TicksRemaining: 12, Intensity: 0.7})
		return true
	}
	return false
}

func (w *World) updateProjectiles() {
	live := w.Projectiles[:0]
	for _, projectile := range w.Projectiles {
		if projectile.TicksRemaining <= 0 {
			continue
		}
		previous := projectile.Pos
		projectile.Pos = projectile.Pos.Add(projectile.Velocity)
		projectile.TicksRemaining--
		if blocked, _ := w.firstProjectileBlock(previous, projectile.Pos); blocked {
			w.Effects = append(w.Effects, Effect{Kind: EffectImpact, Pos: projectile.Pos, Radius: 8, TicksRemaining: 6})
			continue
		}
		if projectile.FromEnemy && projectile.Pos.Distance(w.Player.Pos) <= projectile.Radius+w.Player.radius() {
			w.damagePlayer(projectile.Damage, projectile.Velocity.Normalized().Scale(4), projectile.Hazard)
			continue
		}
		if projectile.TicksRemaining > 0 && projectile.Pos.X >= 0 && projectile.Pos.X <= ArenaW && projectile.Pos.Y >= 0 && projectile.Pos.Y <= ArenaH {
			live = append(live, projectile)
		}
	}
	w.Projectiles = live
}

func (w *World) spawnAimedFan(origin, target Vec, count int, speed float64, damage int) {
	direction := target.Sub(origin).Normalized()
	perpendicular := Vec{X: -direction.Y, Y: direction.X}
	for i := range count {
		offset := (float64(i) - float64(count-1)/2) * 0.24
		w.Projectiles = append(w.Projectiles, &Projectile{ID: w.nextEntityID(), Pos: origin, Velocity: direction.Add(perpendicular.Scale(offset)).Normalized().Scale(speed), Radius: 5, Damage: damage, TicksRemaining: 130, FromEnemy: true, Hazard: true})
	}
}

func (w *World) spawnRadial(origin Vec, count int, speed float64, damage int) {
	for i := range count {
		angle := float64(i) * 6.28318530718 / float64(count)
		w.Projectiles = append(w.Projectiles, &Projectile{ID: w.nextEntityID(), Pos: origin, Velocity: Vec{X: cos(angle) * speed, Y: sin(angle) * speed}, Radius: 6, Damage: damage, TicksRemaining: 120, FromEnemy: true, Hazard: true})
	}
}

func (w *World) damagePlayer(damage int, knockback Vec, hazard bool) {
	p := &w.Player
	if p.Action == ActionDead || p.Invulnerable > 0 || (hazard && p.Form == FormBird) {
		return
	}
	p.HP -= damage
	p.Velocity = knockback
	p.Stagger, p.Invulnerable = 10, 18
	w.hitFeedback(p.Pos, knockback.Normalized())
	if p.HP <= 0 {
		p.HP = 0
		p.Action = ActionDead
		p.Deaths++
		w.Lost = true
	}
}

func (w *World) movePlayerPhysics(horizontal float64) {
	p := &w.Player
	p.Velocity.Y = min(14, p.Velocity.Y+rulesFor(p.Form).Gravity)
	w.movePlayerDirect(Vec{X: horizontal + p.Velocity.X, Y: p.Velocity.Y})
	p.Velocity.X *= 0.74
	w.applyPlayerHazard()
}

func (w *World) movePlayerDirect(delta Vec) {
	p := &w.Player
	next, grounded := w.moveBody(p.Pos, delta, p.radius(), p.Form)
	p.Pos, p.Grounded = next, grounded
	if grounded && p.Velocity.Y > 0 {
		p.Velocity.Y = 0
	}
}

func (w *World) moveEchoPhysics(clone *Clone, horizontal float64) {
	clone.Velocity.Y = min(14, clone.Velocity.Y+rulesFor(clone.Form).Gravity)
	w.moveEchoDirect(clone, Vec{X: horizontal + clone.Velocity.X, Y: clone.Velocity.Y})
	clone.Velocity.X *= 0.74
}

func (w *World) moveEchoDirect(clone *Clone, delta Vec) {
	next, grounded := w.moveBody(clone.Pos, delta, clone.Radius, clone.Form)
	clone.Pos, clone.Grounded = next, grounded
	if grounded && clone.Velocity.Y > 0 {
		clone.Velocity.Y = 0
	}
}

func (w *World) moveEnemyPhysics(enemy *Enemy, horizontal float64) {
	enemy.Velocity.Y = min(14, enemy.Velocity.Y+Gravity)
	next, grounded := w.moveBody(enemy.Pos, Vec{X: horizontal + enemy.Velocity.X, Y: enemy.Velocity.Y}, enemy.Radius, FormMonkey)
	blocked := next.X == enemy.Pos.X && math.Abs(horizontal+enemy.Velocity.X) > 0.1
	enemy.Pos, enemy.Grounded = next, grounded
	if grounded && enemy.Velocity.Y > 0 {
		enemy.Velocity.Y = 0
	}
	if blocked && math.Abs(enemy.Velocity.X) > 5 {
		enemy.Stagger = max(enemy.Stagger, 12)
		enemy.HP -= max(1, int(math.Abs(enemy.Velocity.X)/2))
		w.heavyFeedback(enemy.Pos, Vec{X: enemy.Velocity.X})
	}
}

// moveBody is the side-view collision authority. Walls, pillars, and intact
// cracked walls are full solids; platforms catch a falling body only from above.
func (w *World) moveBody(position, delta Vec, radius float64, form FormID) (Vec, bool) {
	next := position
	next.X = clamp(position.X+delta.X, radius, ArenaW-radius)
	for _, terrain := range w.Terrain {
		if !terrain.solid() || !terrain.Bounds.overlapsCircle(next, radius) {
			continue
		}
		if delta.X > 0 {
			next.X = min(next.X, terrain.Bounds.X-radius)
		} else if delta.X < 0 {
			next.X = max(next.X, terrain.Bounds.X+terrain.Bounds.W+radius)
		}
	}

	grounded := false
	previousY := position.Y
	next.Y = clamp(position.Y+delta.Y, radius, ArenaH-radius)
	for _, terrain := range w.Terrain {
		bounds := terrain.Bounds
		if terrain.Kind == TerrainPlatform {
			if delta.Y >= 0 && previousY+radius <= bounds.Y+1 && next.Y+radius >= bounds.Y && next.X+radius > bounds.X && next.X-radius < bounds.X+bounds.W {
				next.Y = bounds.Y - radius
				grounded = true
			}
			continue
		}
		if !terrain.solid() || !bounds.overlapsCircle(next, radius) {
			continue
		}
		if delta.Y > 0 && previousY+radius <= bounds.Y+radius {
			next.Y = min(next.Y, bounds.Y-radius)
			grounded = true
		} else if delta.Y < 0 && previousY-radius >= bounds.Y+bounds.H-radius {
			next.Y = max(next.Y, bounds.Y+bounds.H+radius)
		}
	}
	if next.Y >= ArenaH-radius {
		grounded = true
	}
	return next, grounded
}

func (w *World) applyPlayerHazard() {
	p := &w.Player
	for _, terrain := range w.Terrain {
		if terrain.Kind == TerrainWater && terrain.Bounds.overlapsCircle(p.Pos, p.radius()) {
			w.damagePlayer(12, Vec{Y: -6}, true)
			return
		}
	}
}
func (w *World) firstTerrainBlock(start, end Vec) (bool, Vec) {
	for step := 1; step <= 20; step++ {
		point := start.Add(end.Sub(start).Scale(float64(step) / 20))
		for _, terrain := range w.Terrain {
			if terrain.blocksProjectile() && terrain.Bounds.contains(point) {
				return true, point
			}
		}
	}
	return false, end
}
func (w *World) firstProjectileBlock(start, end Vec) (bool, Vec) {
	return w.firstTerrainBlock(start, end)
}
func (w *World) breakTerrainAlong(start, end Vec) {
	for index := range w.Terrain {
		terrain := &w.Terrain[index]
		if terrain.Kind == TerrainBreakable && terrain.HP > 0 && (terrain.Bounds.contains(start) || terrain.Bounds.contains(end) || terrain.Bounds.overlapsCircle(end, 14)) {
			terrain.HP--
			w.heavyFeedback(Vec{X: terrain.Bounds.X + terrain.Bounds.W/2, Y: terrain.Bounds.Y + terrain.Bounds.H/2}, end.Sub(start).Normalized())
		}
	}
}

func (w *World) resolveBodyCollisions() {
	for _, enemy := range w.Enemies {
		if !enemy.alive() {
			continue
		}
		delta := w.Player.Pos.Sub(enemy.Pos)
		distance := delta.Length()
		minDistance := w.Player.radius() + enemy.Radius
		if distance > 0 && distance < minDistance {
			push := delta.Scale((minDistance - distance) / distance)
			playerPos, playerGrounded := w.moveBody(w.Player.Pos, Vec{X: push.X * 0.55}, w.Player.radius(), w.Player.Form)
			enemyPos, enemyGrounded := w.moveBody(enemy.Pos, Vec{X: -push.X * 0.45}, enemy.Radius, FormMonkey)
			w.Player.Pos, w.Player.Grounded = playerPos, playerGrounded
			enemy.Pos, enemy.Grounded = enemyPos, enemyGrounded
		}
	}
}

func (w *World) hitFeedback(position, direction Vec) {
	w.Hitstop = max(w.Hitstop, 2)
	w.addTraumaAt(0.16, direction)
	w.Effects = append(w.Effects, Effect{Kind: EffectImpact, Pos: position, Direction: direction, Radius: 13, TicksRemaining: 8, Intensity: 0.3})
}
func (w *World) heavyFeedback(position, direction Vec) {
	w.Hitstop = max(w.Hitstop, 5)
	w.addTraumaAt(0.58, direction)
	w.Effects = append(w.Effects, Effect{Kind: EffectHeavyImpact, Pos: position, Direction: direction, Radius: 26, TicksRemaining: 15, Intensity: 0.9})
}
func (w *World) addTrauma(value float64) { w.Trauma = min(1.25, w.Trauma+value) }

func (w *World) addTraumaAt(value float64, direction Vec) {
	w.addTrauma(value)
	if direction.LengthSq() > 0 {
		w.TraumaDirection = w.TraumaDirection.Add(direction.Normalized().Scale(value)).Normalized()
	}
}

func (w *World) removeDead() {
	live := w.Enemies[:0]
	for _, enemy := range w.Enemies {
		if enemy.HP <= 0 {
			w.Effects = append(w.Effects, Effect{Kind: EffectDeath, Pos: enemy.Pos, Radius: enemy.Radius + 10, TicksRemaining: 18, Intensity: 0.7})
			w.heavyFeedback(enemy.Pos, Vec{X: 1})
			continue
		}
		live = append(live, enemy)
	}
	w.Enemies = live
	if len(w.Enemies) == 0 && !w.Lost {
		w.Won = true
	}
}
func (w *World) updateEffects() {
	live := w.Effects[:0]
	for _, effect := range w.Effects {
		effect.TicksRemaining--
		if effect.TicksRemaining > 0 {
			live = append(live, effect)
		}
	}
	w.Effects = live
}
func decrement(value *int) {
	if *value > 0 {
		*value--
	}
}

func (w *World) StateHash() uint64 {
	h := fnv.New64a()
	p := w.Player
	_, _ = fmt.Fprintf(h, "%s/t%d/r%d/n%d/h%d/s%d/l%d/w%d", SimulationVersion, w.Tick, w.RNG, w.nextID, w.Hitstop, w.SlowTicks, boolHash(w.Won), boolHash(w.Lost))
	_, _ = fmt.Fprintf(h, "/p%d,%d/%d,%d/%d,%d/hp%d/f%d/st%d/a%d/at%d/c%d/b%d/d%d/i%d/t%d/cl%d/g%d/cw%d/lc%d/lr%d/bm%d/gr%d", q(p.Pos.X), q(p.Pos.Y), q(p.Velocity.X), q(p.Velocity.Y), q(p.Aim.X), q(p.Aim.Y), p.HP, p.Form, p.Staff, p.Action, p.ActionTick, p.Combo, p.AttackBuffer, p.DodgeCooldown, p.Invulnerable, p.TransformCooldown, p.CloneCooldown, p.Stagger, p.CounterWindow, p.LongCharge, q(p.LongRange), p.BirdMomentum, boolHash(p.Grounded))
	hashHitIDs(h, p.AttackHitIDs)
	for _, terrain := range w.Terrain {
		_, _ = fmt.Fprintf(h, "/t%d/%d/%d", terrain.ID, terrain.Kind, terrain.HP)
	}
	for _, enemy := range w.Enemies {
		_, _ = fmt.Fprintf(h, "/e%d/k%d/h%d/p%d,%d/v%d,%d/f%d,%d/gr%d/a%d/ac%d/w%d/st%d/wp%d/fl%d/i%d/target%d/ai%s", enemy.ID, enemy.Kind, enemy.HP, q(enemy.Pos.X), q(enemy.Pos.Y), q(enemy.Velocity.X), q(enemy.Velocity.Y), q(enemy.Facing.X), q(enemy.Facing.Y), boolHash(enemy.Grounded), enemy.Armor, enemy.AttackCooldown, enemy.Windup, enemy.Stagger, enemy.WeakPoint, enemy.Flash, enemy.Invulnerable, enemy.TargetCloneID, enemy.AIState)
		if enemy.Boss != nil {
			boss := enemy.Boss
			_, _ = fmt.Fprintf(h, "/b%d/%s/%d/%d/%d/%d/%d", boss.Phase, boss.PhaseName, boss.Timer, boolHash(boss.Shielded), boolHash(boss.EchoSeal), boss.TelegraphTicks, boss.VulnerableTicks)
		}
	}
	for _, clone := range w.Clones {
		_, _ = fmt.Fprintf(h, "/c%d/%d,%d/%d,%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/gr%d", clone.ID, q(clone.Pos.X), q(clone.Pos.Y), q(clone.Aim.X), q(clone.Aim.Y), clone.Form, clone.Staff, clone.Action, clone.ActionTick, clone.LongCharge, q(clone.LongRange), clone.EchoIndex, clone.TicksRemaining, len(clone.Frames), boolHash(clone.Grounded))
		hashHitIDs(h, clone.HitIDs)
	}
	for _, projectile := range w.Projectiles {
		_, _ = fmt.Fprintf(h, "/r%d/%d,%d/%d,%d/%d/%d/%d/%d/%d", projectile.ID, q(projectile.Pos.X), q(projectile.Pos.Y), q(projectile.Velocity.X), q(projectile.Velocity.Y), q(projectile.Radius), projectile.Damage, projectile.TicksRemaining, boolHash(projectile.FromEnemy), boolHash(projectile.Hazard))
	}
	for _, input := range w.inputHistory {
		_, _ = fmt.Fprintf(h, "/i%d/%d,%d/%d/%d/%d/%d/%d/%d/%d/%d", input.MoveX, input.AimX, input.AimY, boolHash(input.Jump), boolHash(input.Attack), boolHash(input.Dodge), boolHash(input.Clone), input.Staff, input.Transform, boolHash(input.Restart), boolHash(input.DebugStep))
	}
	return h.Sum64()
}

func hashHitIDs(h hash.Hash, hitIDs map[int]bool) {
	ids := make([]int, 0, len(hitIDs))
	for id, hit := range hitIDs {
		if hit {
			ids = append(ids, id)
		}
	}
	sort.Ints(ids)
	for _, id := range ids {
		_, _ = fmt.Fprintf(h, "/x%d", id)
	}
}

func boolHash(value bool) int {
	if value {
		return 1
	}
	return 0
}

func q(value float64) int64     { return int64(value * 1000) }
func sin(value float64) float64 { return math.Sin(value) }
func cos(value float64) float64 { return math.Cos(value) }
