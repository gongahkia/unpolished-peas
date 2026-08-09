package sim

import (
	"math"
	"strconv"

	"github.com/gongahkia/journey-roguelite/data/bosses"
	"github.com/gongahkia/journey-roguelite/internal/bossdsl"
)

// BossState pairs generic pattern execution state with combat-only boss data.
// It contains no renderer state, so boss encounters remain replayable.
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
	Program        *bossdsl.Program
	Code           []bossdsl.Instruction
	WaitTicks      int
}

func newBossState(id string) *BossState {
	program := bosses.MustProgram(id)
	state := &BossState{ID: id, PhaseName: program.Phases[0].Name, Program: program}
	state.Code = flattenInstructions(program.Phases[0].Code)
	return state
}

// updateBoss advances a compiled authored pattern. Sequencing, waiting,
// repetition, and phase transitions are generic runtime work; named commands
// map to a deliberately small set of deterministic world effects.
func (w *World) updateBoss(enemy *Enemy) {
	boss := enemy.Boss
	boss.PatternTick++
	if boss.Vulnerable > 0 {
		boss.Vulnerable--
		if boss.Vulnerable == 0 {
			boss.Shielded = true
		}
	}
	for index, phase := range boss.Program.Phases {
		if index <= boss.Phase || !phaseMatches(enemy, phase.Condition) {
			continue
		}
		boss.Phase = index
		boss.PhaseName = phase.Name
		boss.Enraged = index > 0
		boss.PatternCursor = 0
		boss.WaitTicks = 0
		boss.Code = flattenInstructions(phase.Code)
		break
	}
	if boss.WaitTicks > 0 {
		boss.WaitTicks--
		return
	}
	for range 16 { // prevent a malformed no-wait source from burning one tick.
		if len(boss.Code) == 0 {
			return
		}
		if boss.PatternCursor >= len(boss.Code) {
			boss.PatternCursor = 0
		}
		instruction := boss.Code[boss.PatternCursor]
		boss.PatternCursor++
		if w.executeBossInstruction(enemy, instruction) {
			return
		}
	}
}

func phaseMatches(enemy *Enemy, condition *bossdsl.Condition) bool {
	if condition == nil || condition.Field != "hp" {
		return false
	}
	value, err := strconv.Atoi(condition.Value)
	if err != nil {
		return false
	}
	percent := 100 * enemy.HP / enemy.MaxHP
	switch condition.Operator {
	case "<":
		return percent < value
	case ">":
		return percent > value
	case "=":
		return percent == value
	default:
		return false
	}
}

// executeBossInstruction returns true when execution should yield until a
// future simulation tick. Parallel blocks flatten into same-tick operations;
// the resulting effects are independent world changes, never goroutines.
func (w *World) executeBossInstruction(enemy *Enemy, instruction bossdsl.Instruction) bool {
	boss := enemy.Boss
	switch instruction.Op {
	case bossdsl.OpWait:
		boss.WaitTicks = instructionTicks(instruction.Args)
		return true
	case bossdsl.OpTelegraph:
		name := firstArgument(instruction.Args)
		boss.TelegraphTicks = instructionTicks(instruction.Args[1:])
		if boss.TelegraphTicks == 0 {
			boss.TelegraphTicks = 30
		}
		switch name {
		case "wind_wall":
			boss.Shielded, boss.RequiredStaff, boss.Telegraph = true, StaffLong, "wind wall: long staff"
		case "form_ward":
			forms := []FormID{FormTiger, FormSparrow, FormMantis}
			boss.Shielded = true
			boss.RequiredForm = forms[w.Random()%uint64(len(forms))]
			boss.Telegraph = "jade ward: " + boss.RequiredForm.String()
		case "mirror_seal":
			boss.Shielded, boss.Telegraph = true, "mirror seal: clone strike"
		default:
			boss.Telegraph = name
		}
		w.Effects = append(w.Effects, Effect{Kind: EffectTelegraph, Pos: enemy.Pos, Radius: telegraphRadius(name), TicksRemaining: boss.TelegraphTicks})
	case bossdsl.OpAttack:
		switch firstArgument(instruction.Args) {
		case "radial_wind":
			w.spawnRadial(enemy.Pos, 6+boss.Phase*2, 2.8+float64(boss.Phase)*0.4, 9)
		case "jade_radial":
			w.spawnRadial(enemy.Pos, 5+boss.Phase*2, 3.1, 10)
		case "mirror_burst":
			w.spawnRadial(enemy.Pos, 8+boss.Phase*2, 3.3, 11)
		}
	case bossdsl.OpSpawn:
		w.spawnBossThing(enemy, firstArgument(instruction.Args), instructionCount(instruction.Args[1:]))
	case bossdsl.OpMove:
		if firstArgument(instruction.Args) == "player" {
			direction := w.Player.Pos.Sub(enemy.Pos).Normalized()
			enemy.Pos = clampArena(enemy.Pos.Add(direction.Scale(24)), enemy.Radius)
		}
	case bossdsl.OpTransition:
		for index, phase := range boss.Program.Phases {
			if phase.Name == firstArgument(instruction.Args) {
				boss.Phase, boss.PhaseName, boss.PatternCursor = index, phase.Name, 0
				boss.Code = flattenInstructions(phase.Code)
				break
			}
		}
	}
	return false
}

func flattenInstructions(code []bossdsl.Instruction) []bossdsl.Instruction {
	var result []bossdsl.Instruction
	for _, instruction := range code {
		switch instruction.Op {
		case bossdsl.OpSequence, bossdsl.OpParallel:
			result = append(result, flattenInstructions(instruction.Children)...)
		case bossdsl.OpRepeat:
			for range instruction.Count {
				result = append(result, flattenInstructions(instruction.Children)...)
			}
		default:
			result = append(result, instruction)
		}
	}
	return result
}

func instructionTicks(arguments []string) int {
	if len(arguments) == 0 {
		return 0
	}
	value, err := strconv.Atoi(arguments[0])
	if err != nil || value < 1 {
		return 0
	}
	if len(arguments) > 1 && arguments[1] == "ms" {
		return max(1, value*TickRate/1000)
	}
	return value
}

func instructionCount(arguments []string) int {
	if count := instructionTicks(arguments); count > 0 {
		return count
	}
	return 1
}

func firstArgument(arguments []string) string {
	if len(arguments) == 0 {
		return ""
	}
	return arguments[0]
}

func telegraphRadius(name string) float64 {
	switch name {
	case "wind_wall":
		return 132
	case "form_ward":
		return 86
	default:
		return 108
	}
}

func (w *World) spawnBossThing(enemy *Enemy, name string, count int) {
	if name == "fire_orb" {
		w.spawnRadial(enemy.Pos, count, 3.2, 9)
		return
	}
	for range count {
		angle := float64(w.Random()%628) / 100
		position := enemy.Pos.Add(Vec{X: math.Cos(angle), Y: math.Sin(angle)}.Scale(80))
		w.SpawnEnemy(EnemyYaoguai, clampArena(position, 10))
		enemy.Boss.SummonsSpawned++
	}
}

func (w *World) spawnRadial(origin Vec, count int, speed float64, damage int) {
	for i := range count {
		angle := float64(i) * (2 * math.Pi / float64(count))
		velocity := Vec{X: math.Cos(angle) * speed, Y: math.Sin(angle) * speed}
		w.Projectiles = append(w.Projectiles, &Projectile{ID: w.nextEntityID(), Pos: origin, Velocity: velocity, Radius: 6, Damage: damage, TicksRemaining: 120, FromEnemy: true, Hazard: true})
	}
}
