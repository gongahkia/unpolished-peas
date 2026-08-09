package sim

// RenderSnapshot is a read-only projection of World for any renderer. It has
// no Ebitengine types so headless simulations stay independent of graphics.
type RenderSnapshot struct {
	Tick        uint64
	Seed        uint64
	Player      PlayerSnapshot
	Enemies     []EnemySnapshot
	Clones      []CloneSnapshot
	Projectiles []ProjectileSnapshot
	Effects     []EffectSnapshot
	Debug       DebugSnapshot
	Won, Lost   bool
}

type PlayerSnapshot struct {
	Pos, Velocity Vec
	Radius        float64
	HP, MaxHP     int
	Form          FormID
	Staff         StaffLength
	Action        Action
	ActionTick    int
	Invulnerable  bool
}

type EnemySnapshot struct {
	ID              int
	Kind            EnemyKind
	Name            string
	Pos, Velocity   Vec
	Radius          float64
	HP, MaxHP       int
	Windup, Stagger int
	TargetCloneID   int
	AIState         string
	Boss            *BossSnapshot
}

type BossSnapshot struct {
	ID, PhaseName string
	Phase         int
	Shielded      bool
	Telegraph     string
	RequiredForm  FormID
	RequiredStaff StaffLength
}

type CloneSnapshot struct {
	ID             int
	Pos, Facing    Vec
	Radius         float64
	TicksRemaining int
	PendingAttack  int
}

type ProjectileSnapshot struct {
	Pos    Vec
	Radius float64
	Hazard bool
}

type EffectSnapshot struct {
	Kind           EffectKind
	Pos, Direction Vec
	Radius         float64
	TicksRemaining int
}

type DebugSnapshot struct {
	Enabled   bool
	Hitstop   int
	RNG       uint64
	Action    Action
	BossPhase string
}

func (w *World) Snapshot() RenderSnapshot {
	snapshot := RenderSnapshot{
		Tick: w.Tick, Seed: w.Seed, Won: w.Won, Lost: w.Lost,
		Player: PlayerSnapshot{Pos: w.Player.Pos, Velocity: w.Player.Velocity, Radius: w.Player.radius(), HP: w.Player.HP, MaxHP: w.Player.MaxHP, Form: w.Player.Form, Staff: w.Player.Staff, Action: w.Player.Action, ActionTick: w.Player.ActionTick, Invulnerable: w.Player.Invulnerable > 0},
		Debug:  DebugSnapshot{Enabled: w.Debug, Hitstop: w.Hitstop, RNG: w.RNG, Action: w.Player.Action},
	}
	for _, enemy := range w.Enemies {
		entry := EnemySnapshot{ID: enemy.ID, Kind: enemy.Kind, Name: enemy.Name, Pos: enemy.Pos, Velocity: enemy.Velocity, Radius: enemy.Radius, HP: enemy.HP, MaxHP: enemy.MaxHP, Windup: enemy.Windup, Stagger: enemy.Stagger, TargetCloneID: enemy.TargetCloneID, AIState: enemy.AIState}
		if enemy.Boss != nil {
			entry.Boss = &BossSnapshot{ID: enemy.Boss.ID, PhaseName: enemy.Boss.PhaseName, Phase: enemy.Boss.Phase, Shielded: enemy.Boss.Shielded, Telegraph: enemy.Boss.Telegraph, RequiredForm: enemy.Boss.RequiredForm, RequiredStaff: enemy.Boss.RequiredStaff}
			snapshot.Debug.BossPhase = enemy.Boss.PhaseName
		}
		snapshot.Enemies = append(snapshot.Enemies, entry)
	}
	for _, clone := range w.Clones {
		snapshot.Clones = append(snapshot.Clones, CloneSnapshot{ID: clone.ID, Pos: clone.Pos, Facing: clone.Facing, Radius: clone.Radius, TicksRemaining: clone.TicksRemaining, PendingAttack: clone.PendingAttack})
	}
	for _, projectile := range w.Projectiles {
		snapshot.Projectiles = append(snapshot.Projectiles, ProjectileSnapshot{Pos: projectile.Pos, Radius: projectile.Radius, Hazard: projectile.Hazard})
	}
	for _, effect := range w.Effects {
		snapshot.Effects = append(snapshot.Effects, EffectSnapshot{Kind: effect.Kind, Pos: effect.Pos, Direction: effect.Direction, Radius: effect.Radius, TicksRemaining: effect.TicksRemaining})
	}
	return snapshot
}
