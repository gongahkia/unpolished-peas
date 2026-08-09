package sim

// BossState is the authored state machine for the single 72 validation boss.
// It creates clear mechanical asks rather than a damage-race pattern.
type BossState struct {
	Phase           int
	PhaseName       string
	Timer           int
	Shielded        bool
	EchoSeal        bool
	Telegraph       string
	TelegraphTicks  int
	VulnerableTicks int
}

func newArenaBoss() *BossState { return &BossState{PhaseName: "measure"} }

func (w *World) updateBoss(enemy *Enemy) {
	boss := enemy.Boss
	boss.Timer++
	if boss.TelegraphTicks > 0 {
		boss.TelegraphTicks--
		if boss.TelegraphTicks == 0 {
			boss.Telegraph = ""
		}
	}
	if enemy.HP*100 < enemy.MaxHP*55 && boss.Phase == 0 {
		boss.Phase = 1
		boss.PhaseName = "echo trial"
		boss.Timer = 0
		boss.Shielded = false
		boss.EchoSeal = false
		w.addTrauma(0.8)
		w.Hitstop = max(w.Hitstop, 7)
		w.Effects = append(w.Effects, Effect{Kind: EffectHeavyImpact, Pos: enemy.Pos, Radius: 56, TicksRemaining: 24, Intensity: 1})
	}
	if boss.VulnerableTicks > 0 {
		boss.VulnerableTicks--
	}
	cycle := boss.Timer % 210
	if boss.Phase == 0 {
		switch cycle {
		case 1:
			boss.Shielded, boss.EchoSeal = true, false
			boss.Telegraph, boss.TelegraphTicks = "long staff breaks the water line", 48
			w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: 132, TicksRemaining: 48})
		case 49:
			w.spawnAimedFan(enemy.Pos, w.Player.Pos, 3, 4.2, 9)
		case 105:
			boss.Telegraph, boss.TelegraphTicks = "crushing sweep — counter or cross water", 34
			w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: 72, TicksRemaining: 34})
		case 139:
			w.bossSweep(enemy)
		}
		return
	}
	switch cycle {
	case 1:
		boss.Shielded, boss.EchoSeal = true, true
		boss.Telegraph, boss.TelegraphTicks = "echo seal — an Echo must strike", 58
		w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: 118, TicksRemaining: 58})
	case 59:
		w.spawnRadial(enemy.Pos, 8, 3.4, 10)
	case 116:
		boss.Telegraph, boss.TelegraphTicks = "pounce lane — break the cracked wall", 38
		w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: 102, TicksRemaining: 38})
	case 154:
		w.bossSweep(enemy)
	}
}

func (w *World) tryOpenBoss(enemy *Enemy, fromEcho bool) bool {
	boss := enemy.Boss
	if !boss.Shielded {
		return true
	}
	if (boss.EchoSeal && fromEcho) || (!boss.EchoSeal && w.Player.Staff == StaffLong && w.Player.Action == ActionLongRelease) {
		boss.Shielded = false
		boss.VulnerableTicks = 110
		boss.Telegraph = "guard shattered"
		enemy.Stagger = max(enemy.Stagger, 32)
		w.addTrauma(0.8)
		w.Hitstop = max(w.Hitstop, 6)
		w.Effects = append(w.Effects, Effect{Kind: EffectHeavyImpact, Pos: enemy.Pos, Radius: 45, TicksRemaining: 18, Intensity: 1})
		return true
	}
	w.Effects = append(w.Effects, Effect{Kind: EffectImpact, Pos: enemy.Pos, Radius: 10, TicksRemaining: 6})
	return false
}

func (w *World) bossSweep(enemy *Enemy) {
	direction := w.Player.Pos.Sub(enemy.Pos).Normalized()
	end := enemy.Pos.Add(direction.Scale(98))
	w.Effects = append(w.Effects, Effect{Kind: EffectStaffTrail, Pos: enemy.Pos, Direction: direction, Radius: 98, TicksRemaining: 9, Intensity: 0.8})
	if nearestPointOnSegment(w.Player.Pos, enemy.Pos, end).Distance(w.Player.Pos) <= 22+w.Player.radius() {
		w.damagePlayer(18, direction.Scale(10), false)
	}
}
