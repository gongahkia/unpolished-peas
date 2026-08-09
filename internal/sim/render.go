package sim

// RenderSnapshot is a read-only projection of deterministic lab state. The
// renderer may animate from Tick but cannot modify the simulation.
type RenderSnapshot struct {
	Tick    uint64
	Player  PlayerSnapshot
	Terrain []TerrainSnapshot
	Objects []ObjectSnapshot
	Lab     LabSnapshot
	Debug   bool
	Trauma  float64
	Won     bool
	Lost    bool
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
	Tether        TetherState
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

type LabSnapshot struct {
	Seed    uint64
	Modules []LabModuleInfo
	Exit    Vec
}

func (w *World) Snapshot() RenderSnapshot {
	p := w.Player
	snapshot := RenderSnapshot{
		Tick:   w.Tick,
		Player: PlayerSnapshot{Pos: p.Pos, Velocity: p.Velocity, Aim: p.Aim, Facing: p.Facing, Grounded: p.Grounded, State: p.State, Crouching: p.Crouching, Coyote: p.Coyote, AirJumps: p.AirJumps, WallDirection: p.WallDirection, WallTicks: p.WallTicks, RollTicks: p.RollTicks, LedgeTicks: p.LedgeTicks, LedgeTarget: p.LedgeTarget, HeldObjectID: p.HeldObjectID, Tether: p.Tether},
		Lab:    LabSnapshot{Seed: w.Lab.Seed, Modules: append([]LabModuleInfo(nil), w.Lab.Modules...), Exit: w.Lab.Exit},
		Debug:  w.Debug,
		Trauma: w.Trauma,
		Won:    w.Won,
		Lost:   w.Lost,
	}
	for _, terrain := range w.Terrain {
		snapshot.Terrain = append(snapshot.Terrain, TerrainSnapshot{ID: terrain.ID, Kind: terrain.Kind, Bounds: terrain.Bounds, HP: terrain.HP})
	}
	for _, object := range w.Objects {
		snapshot.Objects = append(snapshot.Objects, ObjectSnapshot{ID: object.ID, Kind: object.Kind, Pos: object.Pos, Size: object.Size, LinkID: object.LinkID, Active: object.Active, Held: object.Held})
	}
	return snapshot
}
