package sim

import "math"

// BossState contains data that the generic enemy loop needs. The pattern
// scheduler fills it; no renderer code is allowed to advance this state.
type BossState struct {
	ID             string
	Phase          int
	PhaseName      string
	Vulnerable     int
	PatternTick    int
	PatternCursor  int
	Enraged        bool
	Shielded       bool
	RequiredForm   FormID
	RequiredStaff  StaffLength
	Telegraph      string
	TelegraphTicks int
	SummonsSpawned int
}

// updateBoss is the Go pattern runtime used while the textual patterns are
// compiled at load time. Each command it emits is a small, testable world
// operation (telegraph, projectile, shield, or summon), rather than a renderer
// concern.
func (w *World) updateBoss(enemy *Enemy) {
	boss := enemy.Boss
	boss.PatternTick++
	if boss.Vulnerable > 0 {
		boss.Vulnerable--
		if boss.Vulnerable == 0 {
			boss.Shielded = true
		}
	}
	health := float64(enemy.HP) / float64(enemy.MaxHP)
	if health < 0.5 && boss.Phase == 0 {
		boss.Phase = 1
		boss.Enraged = true
		boss.PhaseName = "trial"
		boss.PatternTick = 0
	}
	switch boss.ID {
	case "yellow_wind_sage":
		w.updateYellowWind(enemy)
	case "golden_horn":
		w.updateGoldenHorn(enemy)
	case "erlang_mirror":
		w.updateErlangMirror(enemy)
	}
}

func (w *World) updateYellowWind(enemy *Enemy) {
	boss := enemy.Boss
	interval := 180
	if boss.Enraged {
		interval = 120
	}
	if boss.PatternTick%interval == 1 {
		boss.Shielded = true
		boss.RequiredStaff = StaffLong
		boss.Telegraph = "wind wall: long staff"
		boss.TelegraphTicks = 54
		w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: 132, TicksRemaining: 54})
	}
	if boss.PatternTick%interval == 54 {
		w.spawnRadial(enemy.Pos, 6+boss.Phase*2, 2.8+float64(boss.Phase)*0.4, 9)
	}
}

func (w *World) updateGoldenHorn(enemy *Enemy) {
	boss := enemy.Boss
	if boss.PatternTick%150 == 1 {
		forms := []FormID{FormTiger, FormSparrow, FormMantis}
		boss.RequiredForm = forms[(boss.PatternTick/150+int(w.Random()%uint64(len(forms))))%len(forms)]
		boss.Shielded = true
		boss.Telegraph = "jade ward: " + boss.RequiredForm.String()
		boss.TelegraphTicks = 45
		w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: 86, TicksRemaining: 45})
	}
	if boss.PatternTick%150 == 45 {
		w.spawnRadial(enemy.Pos, 5+boss.Phase*2, 3.1, 10)
	}
}

func (w *World) updateErlangMirror(enemy *Enemy) {
	boss := enemy.Boss
	interval := 165
	if boss.Enraged {
		interval = 105
	}
	if boss.PatternTick%interval == 1 {
		boss.Shielded = true
		boss.Telegraph = "mirror seal: clone strike"
		boss.TelegraphTicks = 50
		w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: 108, TicksRemaining: 50})
	}
	if boss.PatternTick%interval == 50 {
		w.spawnRadial(enemy.Pos, 8+boss.Phase*2, 3.3, 11)
	}
	if boss.PatternTick%240 == 100 && boss.SummonsSpawned < 8 {
		angle := float64(w.Random()%628) / 100
		position := enemy.Pos.Add(Vec{X: math.Cos(angle), Y: math.Sin(angle)}.Scale(80))
		w.SpawnEnemy(EnemyYaoguai, clampArena(position, 10))
		boss.SummonsSpawned++
	}
}

func (w *World) spawnRadial(origin Vec, count int, speed float64, damage int) {
	for i := range count {
		angle := float64(i) * (2 * math.Pi / float64(count))
		velocity := Vec{X: math.Cos(angle) * speed, Y: math.Sin(angle) * speed}
		w.Projectiles = append(w.Projectiles, &Projectile{ID: w.nextEntityID(), Pos: origin, Velocity: velocity, Radius: 6, Damage: damage, TicksRemaining: 120, FromEnemy: true, Hazard: true})
	}
}
