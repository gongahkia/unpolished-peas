package sim

// RenderSnapshot is a renderer-only projection. Visual randomness is derived
// from Tick and never mutates World.RNG.
type RenderSnapshot struct {
	Tick            uint64
	Player          PlayerSnapshot
	Enemies         []EnemySnapshot
	Clones          []CloneSnapshot
	Projectiles     []ProjectileSnapshot
	Effects         []EffectSnapshot
	Terrain         []TerrainSnapshot
	Debug           DebugSnapshot
	Trauma          float64
	TraumaDirection Vec
	Won, Lost       bool
}

type PlayerSnapshot struct {
	Pos, Velocity  Vec
	Aim            Vec
	Radius         float64
	HP, MaxHP      int
	Form           FormID
	Staff          StaffLength
	Action         Action
	ActionTick     int
	LongRange      float64
	LongCharge     int
	AttackRange    float64
	AttackWidth    float64
	AttackStartup  int
	AttackActive   int
	AttackRecovery int
	Invulnerable   bool
	Grounded       bool
}

type EnemySnapshot struct {
	ID              int
	Kind            EnemyKind
	Name            string
	Pos, Velocity   Vec
	Radius          float64
	Grounded        bool
	HP, MaxHP       int
	Windup, Stagger int
	WeakPoint       int
	Flash           int
	TargetCloneID   int
	AIState         string
	Boss            *BossSnapshot
}

type BossSnapshot struct {
	PhaseName      string
	Phase          int
	Shielded       bool
	EchoSeal       bool
	Telegraph      string
	TelegraphTicks int
}

type CloneSnapshot struct {
	ID               int
	Pos, Aim         Vec
	Radius           float64
	Grounded         bool
	Delay, EchoIndex int
	EchoLength       int
	TicksRemaining   int
	Action           Action
	LongRange        float64
	ReplayInput      InputFrame
}

type ProjectileSnapshot struct {
	Pos    Vec
	Radius float64
	Hazard bool
}
type EffectSnapshot struct {
	Kind              EffectKind
	Pos, Direction    Vec
	Radius, Intensity float64
	TicksRemaining    int
}
type TerrainSnapshot struct {
	ID     int
	Kind   TerrainKind
	Bounds Rect
	HP     int
}
type DebugSnapshot struct {
	Enabled            bool
	Hitstop, SlowTicks int
	BossPhase          string
}

func (w *World) Snapshot() RenderSnapshot {
	s := RenderSnapshot{Tick: w.Tick, Trauma: w.Trauma, TraumaDirection: w.TraumaDirection, Won: w.Won, Lost: w.Lost, Player: PlayerSnapshot{Pos: w.Player.Pos, Velocity: w.Player.Velocity, Aim: w.Player.Aim, Radius: w.Player.radius(), HP: w.Player.HP, MaxHP: w.Player.MaxHP, Form: w.Player.Form, Staff: w.Player.Staff, Action: w.Player.Action, ActionTick: w.Player.ActionTick, LongRange: w.Player.LongRange, LongCharge: w.Player.LongCharge, AttackRange: w.Player.LastAttackSpec.Range, AttackWidth: w.Player.LastAttackSpec.Width, AttackStartup: w.Player.LastAttackSpec.Startup, AttackActive: w.Player.LastAttackSpec.Active, AttackRecovery: w.Player.LastAttackSpec.Recovery, Invulnerable: w.Player.Invulnerable > 0, Grounded: w.Player.Grounded}, Debug: DebugSnapshot{Enabled: w.Debug, Hitstop: w.Hitstop, SlowTicks: w.SlowTicks}}
	for _, terrain := range w.Terrain {
		s.Terrain = append(s.Terrain, TerrainSnapshot{ID: terrain.ID, Kind: terrain.Kind, Bounds: terrain.Bounds, HP: terrain.HP})
	}
	for _, enemy := range w.Enemies {
		e := EnemySnapshot{ID: enemy.ID, Kind: enemy.Kind, Name: enemy.Name, Pos: enemy.Pos, Velocity: enemy.Velocity, Radius: enemy.Radius, Grounded: enemy.Grounded, HP: enemy.HP, MaxHP: enemy.MaxHP, Windup: enemy.Windup, Stagger: enemy.Stagger, WeakPoint: enemy.WeakPoint, Flash: enemy.Flash, TargetCloneID: enemy.TargetCloneID, AIState: enemy.AIState}
		if enemy.Boss != nil {
			e.Boss = &BossSnapshot{PhaseName: enemy.Boss.PhaseName, Phase: enemy.Boss.Phase, Shielded: enemy.Boss.Shielded, EchoSeal: enemy.Boss.EchoSeal, Telegraph: enemy.Boss.Telegraph, TelegraphTicks: enemy.Boss.TelegraphTicks}
			s.Debug.BossPhase = enemy.Boss.PhaseName
		}
		s.Enemies = append(s.Enemies, e)
	}
	for _, clone := range w.Clones {
		input := InputFrame{}
		if clone.EchoIndex >= 0 && clone.EchoIndex < len(clone.Frames) {
			input = clone.Frames[clone.EchoIndex]
		}
		s.Clones = append(s.Clones, CloneSnapshot{ID: clone.ID, Pos: clone.Pos, Aim: clone.Aim, Radius: clone.Radius, Grounded: clone.Grounded, Delay: clone.Delay, EchoIndex: clone.EchoIndex, EchoLength: len(clone.Frames), TicksRemaining: clone.TicksRemaining, Action: clone.Action, LongRange: clone.LongRange, ReplayInput: input})
	}
	for _, projectile := range w.Projectiles {
		s.Projectiles = append(s.Projectiles, ProjectileSnapshot{Pos: projectile.Pos, Radius: projectile.Radius, Hazard: projectile.Hazard})
	}
	for _, effect := range w.Effects {
		s.Effects = append(s.Effects, EffectSnapshot{Kind: effect.Kind, Pos: effect.Pos, Direction: effect.Direction, Radius: effect.Radius, Intensity: effect.Intensity, TicksRemaining: effect.TicksRemaining})
	}
	return s
}
