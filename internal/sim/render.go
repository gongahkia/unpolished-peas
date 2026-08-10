package sim

// RenderSnapshot is a read-only projection of deterministic run state. The
// renderer may animate from Tick but cannot modify the simulation.
type RenderSnapshot struct {
	Tick    uint64
	Seed    uint64
	Player  PlayerSnapshot
	Terrain []TerrainSnapshot
	Objects []ObjectSnapshot
	Enemies []EnemySnapshot
	Run     RunSnapshot
	Debug   bool
	Trauma  float64
	Impact  ImpactState
	Won     bool
	Lost    bool
	Stats   RunStats
}

type PlayerSnapshot struct {
	Pos, Velocity Vec
	Aim           Vec
	Facing        int8
	Grounded      bool
	State         TraversalState
	Crouching     bool
	Coyote        int
	AirJumps      int
	WallDirection int8
	WallTicks     int
	RollTicks     int
	LedgeTicks    int
	LedgeTarget   Vec
	HeldObjectID  int
}

type TerrainSnapshot struct {
	ID     int
	Kind   TerrainKind
	Bounds Rect
	HP     int
}

type ObjectSnapshot struct {
	ID     int
	Kind   ObjectKind
	Pos    Vec
	Size   Vec
	LinkID int
	Active bool
	Held   bool
}

type EnemySnapshot struct {
	ID        int
	Archetype EnemyArchetype
	State     EnemyState
	Pos, Size Vec
	Velocity  Vec
	Facing    int8
	Grounded  bool
	Timer     int
	Flash     int
}

type RunSnapshot struct {
	Rooms []RunRoom
}

func (w *World) Snapshot() RenderSnapshot {
	p := w.Player
	snapshot := RenderSnapshot{
		Tick:   w.Tick,
		Seed:   w.Seed,
		Player: PlayerSnapshot{Pos: p.Pos, Velocity: p.Velocity, Aim: p.Aim, Facing: p.Facing, Grounded: p.Grounded, State: p.State, Crouching: p.Crouching, Coyote: p.Coyote, AirJumps: p.AirJumps, WallDirection: p.WallDirection, WallTicks: p.WallTicks, RollTicks: p.RollTicks, LedgeTicks: p.LedgeTicks, LedgeTarget: p.LedgeTarget, HeldObjectID: p.HeldObjectID},
		Run:    RunSnapshot{Rooms: append([]RunRoom(nil), w.Run.Rooms...)},
		Debug:  w.Debug,
		Trauma: w.Trauma,
		Impact: w.Impact,
		Won:    w.Won,
		Lost:   w.Lost,
		Stats:  w.Stats,
	}
	for _, terrain := range w.Terrain {
		snapshot.Terrain = append(snapshot.Terrain, TerrainSnapshot{ID: terrain.ID, Kind: terrain.Kind, Bounds: terrain.Bounds, HP: terrain.HP})
	}
	for _, object := range w.Objects {
		snapshot.Objects = append(snapshot.Objects, ObjectSnapshot{ID: object.ID, Kind: object.Kind, Pos: object.Pos, Size: object.Size, LinkID: object.LinkID, Active: object.Active, Held: object.Held})
	}
	for _, enemy := range w.Enemies {
		snapshot.Enemies = append(snapshot.Enemies, EnemySnapshot{ID: enemy.ID, Archetype: enemy.Archetype, State: enemy.State, Pos: enemy.Pos, Size: enemy.Size, Velocity: enemy.Vel, Facing: enemy.Facing, Grounded: enemy.Grounded, Timer: enemy.Timer, Flash: enemy.Flash})
	}
	return snapshot
}
