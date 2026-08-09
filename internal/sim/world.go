package sim

import (
	"fmt"
	"hash/fnv"
)

const SimulationVersion = "0.1.0"

// World is an explicit, deterministic ownership boundary for an encounter.
type World struct {
	Seed        uint64
	Tick        uint64
	RNG         uint64
	Player      Player
	Enemies     []*Enemy
	Clones      []*Clone
	Projectiles []*Projectile
	Effects     []Effect
	Hitstop     int
	Won         bool
	Lost        bool
	Debug       bool
	Vows        map[Vow]bool
	Companion   Companion
	nextID      int
	prevInput   InputFrame
}

func NewWorld(seed uint64) *World {
	if seed == 0 {
		seed = 1
	}
	w := &World{Seed: seed, RNG: seed, Player: newPlayer(), nextID: 1, Vows: make(map[Vow]bool)}
	return w
}

// BeginEncounter clears transient combat state while preserving the run's HP,
// vows, companion, and learned forms.
func (w *World) BeginEncounter() {
	w.Enemies = nil
	w.Clones = nil
	w.Projectiles = nil
	w.Effects = nil
	w.Hitstop = 0
	w.Won = false
	w.Lost = false
	w.Player.Pos = Vec{X: ArenaW / 2, Y: ArenaH / 2}
	w.Player.Velocity = Vec{}
	w.Player.Action = ActionIdle
	w.Player.ActionTick = 0
	w.Player.AttackBuffer = 0
	w.Player.Stagger = 0
	w.Player.Invulnerable = 0
	w.prevInput = InputFrame{}
}

func (w *World) ResetEncounter() {
	seed := w.Seed
	*w = *NewWorld(seed)
}

func (w *World) nextEntityID() int {
	id := w.nextID
	w.nextID++
	return id
}

// Random returns deterministic pseudo-random bits for gameplay decisions.
func (w *World) Random() uint64 {
	w.RNG ^= w.RNG << 13
	w.RNG ^= w.RNG >> 7
	w.RNG ^= w.RNG << 17
	return w.RNG
}

func (w *World) SpawnEnemy(kind EnemyKind, position Vec) *Enemy {
	e := &Enemy{ID: w.nextEntityID(), Kind: kind, Pos: position, Facing: Vec{X: -1}, TargetCloneID: -1}
	switch kind {
	case EnemyArcher:
		e.Name, e.Radius, e.MaxHP, e.Damage, e.MoveSpeed, e.AttackRange = "spitting yaoguai", 8, 34, 8, 1.2, 150
	case EnemyBrute:
		e.Name, e.Radius, e.MaxHP, e.Damage, e.MoveSpeed, e.AttackRange = "iron-hide demon", 14, 80, 16, 0.75, 31
		e.Armor = 6
	case EnemyLancer:
		e.Name, e.Radius, e.MaxHP, e.Damage, e.MoveSpeed, e.AttackRange = "wind-lance demon", 9, 54, 13, 1.75, 70
	case EnemyHexer:
		e.Name, e.Radius, e.MaxHP, e.Damage, e.MoveSpeed, e.AttackRange = "sutra hexer", 8, 48, 9, 0.9, 125
	default:
		e.Name, e.Radius, e.MaxHP, e.Damage, e.MoveSpeed, e.AttackRange = "mountain yaoguai", 10, 42, 10, 1.35, 27
	}
	e.HP = e.MaxHP
	w.Enemies = append(w.Enemies, e)
	return e
}

func (w *World) SpawnBoss(id, name string, position Vec, hp int) *Enemy {
	e := &Enemy{ID: w.nextEntityID(), Kind: EnemyBoss, Name: name, Pos: position, Facing: Vec{X: -1}, Radius: 22, HP: hp, MaxHP: hp, Damage: 18, MoveSpeed: 1.0, AttackRange: 45, TargetCloneID: -1}
	e.Boss = newBossState(id)
	w.Enemies = append(w.Enemies, e)
	return e
}

func (w *World) SpawnClone() {
	p := &w.Player
	if p.CloneCooldown > 0 || p.Action == ActionDead || w.Vows[VowSilence] {
		return
	}
	position := clampArena(p.Pos.Sub(p.Facing.Scale(22)), p.radius())
	w.spawnCloneAt(position, p.Facing)
	if w.Companion == CompanionBajie {
		perpendicular := Vec{X: -p.Facing.Y, Y: p.Facing.X}
		w.spawnCloneAt(clampArena(position.Add(perpendicular.Scale(20)), p.radius()), p.Facing)
	}
	p.CloneCooldown = 120
	w.Effects = append(w.Effects, Effect{Kind: EffectTransform, Pos: position, Radius: 16, TicksRemaining: 16})
}

func (w *World) spawnCloneAt(position, facing Vec) {
	ticks := 300
	if w.Companion == CompanionBajie {
		ticks = 360
	}
	w.Clones = append(w.Clones, &Clone{ID: w.nextEntityID(), Pos: position, Facing: facing, Radius: 7, TicksRemaining: ticks, HitIDs: make(map[int]bool)})
}

func (w *World) Step(input InputFrame) {
	if w.Lost && input.Restart && !w.prevInput.Restart {
		w.ResetEncounter()
		return
	}
	w.Tick++
	if input.Staff != StaffNone {
		w.Player.Staff = input.Staff
	}
	if input.DebugStep && !w.prevInput.DebugStep {
		w.Debug = !w.Debug
	}
	w.handleInput(input)
	w.updateEffects()
	if w.Hitstop > 0 {
		w.Hitstop--
		w.prevInput = input
		return
	}
	w.updatePlayer(input)
	w.updateClones()
	w.updateEnemies()
	w.updateProjectiles()
	w.resolveBodyCollisions()
	w.removeDead()
	w.prevInput = input
}

func (w *World) handleInput(input InputFrame) {
	p := &w.Player
	if input.Attack && !w.prevInput.Attack {
		p.AttackBuffer = 8
	}
	if input.Dodge && !w.prevInput.Dodge && p.DodgeCooldown == 0 {
		if p.Action == ActionIdle || p.attackRecovering() {
			w.startDodge(input)
		}
	}
	if input.Clone && !w.prevInput.Clone {
		w.SpawnClone()
	}
	if input.Transform != FormNone && input.Transform != p.Form && p.TransformCooldown == 0 {
		if w.Vows[VowHumility] && input.Transform == FormGiant {
			return
		}
		p.Form = input.Transform
		p.TransformCooldown = 15
		if w.Vows[VowSilence] {
			p.TransformCooldown = 7
		}
		p.Velocity = Vec{}
		w.Effects = append(w.Effects, Effect{Kind: EffectTransform, Pos: p.Pos, Radius: p.radius() + 8, TicksRemaining: 14})
	}
}

func (w *World) updatePlayer(input InputFrame) {
	p := &w.Player
	decrement := func(value *int) {
		if *value > 0 {
			*value--
		}
	}
	decrement(&p.DodgeCooldown)
	decrement(&p.Invulnerable)
	decrement(&p.TransformCooldown)
	decrement(&p.CloneCooldown)
	decrement(&p.AttackBuffer)
	if p.Action == ActionDead {
		return
	}
	if p.Stagger > 0 {
		p.Stagger--
		p.Pos = clampArena(p.Pos.Add(p.Velocity), p.radius())
		p.Velocity = p.Velocity.Scale(0.78)
		return
	}
	if p.Action == ActionDodge {
		p.Pos = clampArena(p.Pos.Add(p.Velocity), p.radius())
		p.ActionTick++
		if p.ActionTick >= 9 {
			p.Action = ActionIdle
			p.Velocity = Vec{}
		}
		return
	}
	if p.Action == ActionCounter {
		p.ActionTick++
		p.CounterWindow--
		if p.ActionTick >= 12 {
			p.Action = ActionIdle
		}
		return
	}
	rules := rulesFor(p.Form)
	move := Vec{X: float64(input.MoveX), Y: float64(input.MoveY)}
	if move.LengthSq() > 1 {
		move = move.Normalized()
	}
	if move.LengthSq() > 0 {
		p.Facing = move
	}
	if rules.CanMove && p.Action != ActionAttack {
		p.Velocity = move.Scale(3.2 * rules.MoveMultiplier)
		p.Pos = clampArena(p.Pos.Add(p.Velocity), p.radius())
	} else {
		p.Velocity = p.Velocity.Scale(0.65)
	}
	if p.Action == ActionIdle && p.AttackBuffer > 0 && rules.CanAttack {
		w.startAttack()
	}
	if p.Action == ActionAttack {
		if p.attackActive() {
			w.resolveStaffAttack(p.Pos, p.Facing, p.LastAttackSpec, p.AttackHitIDs, false)
		}
		p.ActionTick++
		if p.ActionTick >= p.LastAttackSpec.Total() {
			p.Action = ActionIdle
			if p.Combo >= 2 || p.Staff != StaffMedium {
				p.Combo = 0
			} else {
				p.Combo++
			}
		}
	}
}

func (w *World) startDodge(input InputFrame) {
	p := &w.Player
	direction := Vec{X: float64(input.MoveX), Y: float64(input.MoveY)}
	if direction.LengthSq() == 0 {
		direction = p.Facing
	}
	direction = direction.Normalized()
	p.Action = ActionDodge
	p.ActionTick = 0
	p.DodgeCooldown = 30
	if w.Vows[VowCloudbound] {
		p.DodgeCooldown = 18
	}
	p.Invulnerable = 8
	p.Velocity = direction.Scale(7.5)
	if w.Companion == CompanionWujing {
		w.clearNearbyProjectiles(p.Pos, 36)
	}
}

func (w *World) clearNearbyProjectiles(position Vec, radius float64) {
	live := w.Projectiles[:0]
	for _, projectile := range w.Projectiles {
		if projectile.FromEnemy && projectile.Pos.Distance(position) <= radius+projectile.Radius {
			w.Effects = append(w.Effects, Effect{Kind: EffectCounter, Pos: projectile.Pos, Radius: 10, TicksRemaining: 6})
			continue
		}
		live = append(live, projectile)
	}
	w.Projectiles = live
}

func (w *World) startAttack() {
	p := &w.Player
	if p.Form == FormMantis {
		p.Action, p.ActionTick, p.CounterWindow = ActionCounter, 0, rulesFor(p.Form).CounterTicks
		p.AttackBuffer = 0
		return
	}
	p.Action = ActionAttack
	p.ActionTick = 0
	p.AttackBuffer = 0
	p.LastAttackSpec = p.attackSpec()
	p.AttackHitIDs = make(map[int]bool)
	for _, clone := range w.Clones {
		if clone.PendingAttack == 0 {
			clone.PendingAttack = 12
			clone.AttackSpec = p.LastAttackSpec
			clone.AttackSpec.Damage = max(1, int(float64(clone.AttackSpec.Damage)*0.6))
			clone.HitIDs = make(map[int]bool)
			clone.Facing = p.Facing
		}
	}
}

func (w *World) resolveStaffAttack(origin, facing Vec, spec AttackSpec, hitIDs map[int]bool, fromClone bool) {
	start := origin.Add(facing.Scale(6))
	end := origin.Add(facing.Scale(spec.Range))
	w.Effects = append(w.Effects, Effect{Kind: EffectStaffTrail, Pos: origin, Direction: facing, Radius: spec.Range, TicksRemaining: 3})
	for _, enemy := range w.Enemies {
		if !enemy.alive() || hitIDs[enemy.ID] || enemy.Invulnerable > 0 {
			continue
		}
		nearest := nearestPointOnSegment(enemy.Pos, start, end)
		if enemy.Pos.Distance(nearest) > spec.Width+enemy.Radius {
			continue
		}
		damage := spec.Damage
		if enemy.Boss != nil && enemy.Boss.Shielded {
			w.tryOpenBoss(enemy, fromClone)
			if enemy.Boss.Shielded {
				damage = 0
			}
		}
		if damage == 0 {
			w.Effects = append(w.Effects, Effect{Kind: EffectImpact, Pos: enemy.Pos, Radius: 9, TicksRemaining: 6})
			continue
		}
		if enemy.Armor > 0 {
			if w.Player.Form == FormTiger {
				enemy.Armor = 0
				enemy.Stagger = max(enemy.Stagger, 24)
				w.Effects = append(w.Effects, Effect{Kind: EffectCounter, Pos: enemy.Pos, Radius: 22, TicksRemaining: 10})
			} else {
				damage = max(1, damage-enemy.Armor)
			}
		}
		enemy.HP -= damage
		enemy.Velocity = enemy.Velocity.Add(facing.Scale(spec.Knockback))
		enemy.Stagger = max(enemy.Stagger, 5)
		enemy.LastDamagedByClone = fromClone
		hitIDs[enemy.ID] = true
		w.Hitstop = max(w.Hitstop, 3)
		w.Effects = append(w.Effects, Effect{Kind: EffectImpact, Pos: enemy.Pos, Radius: 13, TicksRemaining: 8})
	}
}

func (w *World) tryOpenBoss(enemy *Enemy, fromClone bool) {
	boss := enemy.Boss
	opened := false
	switch boss.ID {
	case "yellow_wind_sage":
		opened = w.Player.Staff == StaffLong
	case "golden_horn":
		opened = w.Player.Form == boss.RequiredForm
	case "erlang_mirror":
		opened = fromClone
	}
	if opened {
		boss.Shielded = false
		boss.Vulnerable = 90
		boss.Telegraph = "opened"
		w.Effects = append(w.Effects, Effect{Kind: EffectCounter, Pos: enemy.Pos, Radius: enemy.Radius + 18, TicksRemaining: 18})
	}
}

func (w *World) updateClones() {
	live := w.Clones[:0]
	for _, clone := range w.Clones {
		clone.TicksRemaining--
		if clone.PendingAttack > 0 {
			clone.PendingAttack--
			if clone.PendingAttack == 0 {
				w.resolveStaffAttack(clone.Pos, clone.Facing, clone.AttackSpec, clone.HitIDs, true)
			}
		}
		if clone.TicksRemaining > 0 {
			live = append(live, clone)
		}
	}
	w.Clones = live
}

func (w *World) updateEnemies() {
	for _, enemy := range w.Enemies {
		if !enemy.alive() {
			continue
		}
		if enemy.Invulnerable > 0 {
			enemy.Invulnerable--
		}
		if enemy.Boss != nil {
			w.updateBoss(enemy)
		}
		if enemy.Stagger > 0 {
			enemy.AIState = "staggered"
			enemy.Stagger--
			enemy.Pos = clampArena(enemy.Pos.Add(enemy.Velocity), enemy.Radius)
			enemy.Velocity = enemy.Velocity.Scale(0.76)
			continue
		}
		target, clone, canTarget := w.enemyTarget(enemy)
		if !canTarget {
			enemy.AIState = "searching"
			continue
		}
		toTarget := target.Sub(enemy.Pos)
		distance := toTarget.Length()
		if distance > 0 {
			enemy.Facing = toTarget.Scale(1 / distance)
		}
		if enemy.Windup > 0 {
			enemy.AIState = "windup"
			enemy.Windup--
			if enemy.Windup == 0 {
				w.enemyAttack(enemy, target, clone)
			}
			continue
		}
		if enemy.AttackCooldown > 0 {
			enemy.AttackCooldown--
		}
		if distance <= enemy.AttackRange && enemy.AttackCooldown == 0 {
			enemy.AIState = "telegraph"
			enemy.Windup = 18
			w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: target, Radius: enemy.AttackRange, TicksRemaining: 18})
			continue
		}
		if distance > enemy.AttackRange*0.78 {
			enemy.AIState = "chase"
			enemy.Velocity = enemy.Facing.Scale(enemy.MoveSpeed)
			enemy.Pos = clampArena(enemy.Pos.Add(enemy.Velocity), enemy.Radius)
		}
	}
}

func (w *World) enemyTarget(enemy *Enemy) (Vec, *Clone, bool) {
	for _, clone := range w.Clones {
		if rulesFor(w.Player.Form).Untargetable || enemy.Pos.Distance(clone.Pos) < enemy.Pos.Distance(w.Player.Pos)*1.25 {
			enemy.TargetCloneID = clone.ID
			return clone.Pos, clone, true
		}
	}
	if rulesFor(w.Player.Form).Untargetable {
		enemy.TargetCloneID = -1
		return Vec{}, nil, false
	}
	enemy.TargetCloneID = -1
	return w.Player.Pos, nil, true
}

func (w *World) enemyAttack(enemy *Enemy, target Vec, clone *Clone) {
	enemy.AttackCooldown = 45
	if enemy.Kind == EnemyArcher {
		direction := target.Sub(enemy.Pos).Normalized()
		w.Projectiles = append(w.Projectiles, &Projectile{ID: w.nextEntityID(), Pos: enemy.Pos, Velocity: direction.Scale(4), Radius: 5, Damage: enemy.Damage, TicksRemaining: 120, FromEnemy: true})
		return
	}
	if enemy.Kind == EnemyHexer {
		direction := target.Sub(enemy.Pos).Normalized()
		perpendicular := Vec{X: -direction.Y, Y: direction.X}
		for _, offset := range []float64{-0.28, 0, 0.28} {
			velocity := direction.Add(perpendicular.Scale(offset)).Normalized().Scale(3.2)
			w.Projectiles = append(w.Projectiles, &Projectile{ID: w.nextEntityID(), Pos: enemy.Pos, Velocity: velocity, Radius: 4, Damage: enemy.Damage, TicksRemaining: 130, FromEnemy: true, Hazard: true})
		}
		return
	}
	if enemy.Kind == EnemyLancer {
		enemy.Pos = clampArena(enemy.Pos.Add(enemy.Facing.Scale(28)), enemy.Radius)
	}
	if clone != nil {
		clone.TicksRemaining = 0
		w.Effects = append(w.Effects, Effect{Kind: EffectDeath, Pos: clone.Pos, Radius: 12, TicksRemaining: 10})
		return
	}
	if w.Player.Form == FormMantis && w.Player.Action == ActionCounter && w.Player.CounterWindow > 0 {
		enemy.Stagger = 45
		enemy.HP -= 18
		if w.Vows[VowHumility] {
			w.Player.HP = min(w.Player.MaxHP, w.Player.HP+4)
		}
		enemy.Velocity = enemy.Facing.Scale(-8)
		w.Hitstop = max(w.Hitstop, 5)
		w.Effects = append(w.Effects, Effect{Kind: EffectCounter, Pos: w.Player.Pos, Radius: 32, TicksRemaining: 14})
		return
	}
	if w.Player.Form == FormMonkey && w.Player.Staff == StaffShort && w.Player.Action == ActionAttack && w.Player.attackActive() {
		enemy.Stagger = max(enemy.Stagger, 20)
		enemy.HP -= 6
		enemy.Velocity = enemy.Facing.Scale(-6)
		w.Hitstop = max(w.Hitstop, 3)
		w.Effects = append(w.Effects, Effect{Kind: EffectCounter, Pos: w.Player.Pos, Radius: 24, TicksRemaining: 10})
		return
	}
	w.damagePlayer(enemy.Damage, enemy.Facing.Scale(5), false)
}

func (w *World) updateProjectiles() {
	live := w.Projectiles[:0]
	for _, projectile := range w.Projectiles {
		projectile.Pos = projectile.Pos.Add(projectile.Velocity)
		projectile.TicksRemaining--
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

func (w *World) damagePlayer(damage int, knockback Vec, hazard bool) {
	p := &w.Player
	if p.Action == ActionDead || p.Invulnerable > 0 || (hazard && rulesFor(p.Form).HazardImmune) {
		return
	}
	if p.Form == FormStatue {
		damage = (damage + 1) / 2
	}
	if p.Form == FormGiant {
		knockback = knockback.Scale(0.35)
	}
	p.HP -= damage
	p.Velocity = knockback
	p.Stagger = 9
	if p.Form == FormGiant {
		p.Stagger = 4
	}
	p.Invulnerable = 18
	w.Effects = append(w.Effects, Effect{Kind: EffectImpact, Pos: p.Pos, Radius: 16, TicksRemaining: 10})
	if p.HP <= 0 {
		p.HP = 0
		p.Action = ActionDead
		p.Deaths++
		w.Lost = true
	}
}

func (w *World) resolveBodyCollisions() {
	p := &w.Player
	if p.Action == ActionDodge && w.Vows[VowCloudbound] {
		return
	}
	for _, enemy := range w.Enemies {
		if !enemy.alive() {
			continue
		}
		delta := p.Pos.Sub(enemy.Pos)
		distance := delta.Length()
		minimum := p.radius() + enemy.Radius
		if distance == 0 {
			delta, distance = Vec{X: 1}, 1
		}
		if distance < minimum {
			push := delta.Scale((minimum - distance) / distance)
			p.Pos = clampArena(p.Pos.Add(push.Scale(0.55)), p.radius())
			enemy.Pos = clampArena(enemy.Pos.Sub(push.Scale(0.45)), enemy.Radius)
		}
	}
}

func (w *World) removeDead() {
	live := w.Enemies[:0]
	for _, enemy := range w.Enemies {
		if enemy.HP <= 0 {
			w.Effects = append(w.Effects, Effect{Kind: EffectDeath, Pos: enemy.Pos, Radius: enemy.Radius + 6, TicksRemaining: 18})
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

// StateHash is a diagnostics hash for deterministic regression tests.
func (w *World) StateHash() uint64 {
	h := fnv.New64a()
	_, _ = fmt.Fprintf(h, "%s/%d/%d/%t/%t/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d", SimulationVersion, w.Tick, w.RNG, w.Won, w.Lost, w.Player.HP, w.Player.Form, w.Player.Staff, w.Player.Action, w.Player.ActionTick, w.Player.Combo, w.Player.DodgeCooldown, w.Player.Invulnerable, w.Player.TransformCooldown, w.Player.CloneCooldown, w.Player.Stagger, q(w.Player.Pos.X), q(w.Player.Pos.Y), q(w.Player.Velocity.X))
	for _, enemy := range w.Enemies {
		_, _ = fmt.Fprintf(h, "/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d", enemy.ID, enemy.Kind, enemy.HP, q(enemy.Pos.X), q(enemy.Pos.Y), q(enemy.Velocity.X), q(enemy.Velocity.Y), enemy.AttackCooldown, enemy.Windup, enemy.Stagger)
		if enemy.Boss != nil {
			_, _ = fmt.Fprintf(h, "/b/%s/%d/%d/%d/%t/%t", enemy.Boss.ID, enemy.Boss.Phase, enemy.Boss.PatternTick, enemy.Boss.Vulnerable, enemy.Boss.Shielded, enemy.Boss.Enraged)
		}
	}
	for _, clone := range w.Clones {
		_, _ = fmt.Fprintf(h, "/c%d/%d/%d/%d/%d", clone.ID, clone.TicksRemaining, clone.PendingAttack, q(clone.Pos.X), q(clone.Pos.Y))
	}
	for _, projectile := range w.Projectiles {
		_, _ = fmt.Fprintf(h, "/p%d/%d/%d/%d/%d/%t/%t", projectile.ID, q(projectile.Pos.X), q(projectile.Pos.Y), q(projectile.Velocity.X), q(projectile.Velocity.Y), projectile.FromEnemy, projectile.Hazard)
	}
	return h.Sum64()
}

func q(value float64) int64 { return int64(value * 1000) }
