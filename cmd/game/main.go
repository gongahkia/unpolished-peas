package main

import (
	"fmt"
	"image/color"
	"log"
	"math"
	"strings"

	"github.com/gongahkia/72/internal/sim"
	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/inpututil"
	"github.com/hajimehoshi/ebiten/v2/text"
	"github.com/hajimehoshi/ebiten/v2/vector"
	"golang.org/x/image/font/basicfont"
)

const (
	logicalW = sim.ViewportW
	logicalH = sim.ViewportH
)

type game struct {
	world  *sim.World
	replay *sim.Replay
	paused bool
	scene  *ebiten.Image
	status string
}

func newGame() *game {
	w := sim.NewValidationWorld(0x72)
	return &game{world: w, replay: sim.NewReplay(w.Seed), scene: ebiten.NewImage(int(sim.ArenaW), int(sim.ArenaH))}
}

func (g *game) Update() error {
	if inpututil.IsKeyJustPressed(ebiten.KeyF1) {
		g.reset()
		g.status = "validation arena reset"
		return nil
	}
	if inpututil.IsKeyJustPressed(ebiten.KeyP) {
		g.paused = !g.paused
	}
	if inpututil.IsKeyJustPressed(ebiten.KeyF6) {
		if err := sim.SaveReplay("72.replay.json", g.replay); err != nil {
			g.status = err.Error()
		} else {
			g.status = "saved 72.replay.json"
		}
	}
	if g.world.Lost && inpututil.IsKeyJustPressed(ebiten.KeyEnter) {
		g.reset()
		return nil
	}
	if g.paused && !inpututil.IsKeyJustPressed(ebiten.KeyPeriod) {
		return nil
	}
	g.replay.Record(g.world, readInput())
	return nil
}

func (g *game) reset() {
	g.world = sim.NewValidationWorld(0x72)
	g.replay = sim.NewReplay(g.world.Seed)
}

func readInput() sim.InputFrame {
	in := sim.InputFrame{}
	if ebiten.IsKeyPressed(ebiten.KeyA) {
		in.MoveX--
	}
	if ebiten.IsKeyPressed(ebiten.KeyD) {
		in.MoveX++
	}
	if ebiten.IsKeyPressed(ebiten.KeyW) {
		in.MoveY--
	}
	if ebiten.IsKeyPressed(ebiten.KeyS) {
		in.MoveY++
	}
	if ebiten.IsKeyPressed(ebiten.KeyArrowLeft) {
		in.AimX--
	}
	if ebiten.IsKeyPressed(ebiten.KeyArrowRight) {
		in.AimX++
	}
	if ebiten.IsKeyPressed(ebiten.KeyArrowUp) {
		in.AimY--
	}
	if ebiten.IsKeyPressed(ebiten.KeyArrowDown) {
		in.AimY++
	}
	if ids := ebiten.AppendGamepadIDs(nil); len(ids) > 0 {
		id := ids[0]
		moveX, moveY := axis(ebiten.GamepadAxisValue(id, 0)), axis(ebiten.GamepadAxisValue(id, 1))
		aimX, aimY := axis(ebiten.GamepadAxisValue(id, 2)), axis(ebiten.GamepadAxisValue(id, 3))
		if in.MoveX == 0 {
			in.MoveX = moveX
		}
		if in.MoveY == 0 {
			in.MoveY = moveY
		}
		if in.AimX == 0 {
			in.AimX = aimX
		}
		if in.AimY == 0 {
			in.AimY = aimY
		}
	}
	in.Attack = ebiten.IsKeyPressed(ebiten.KeyJ) || ebiten.IsMouseButtonPressed(ebiten.MouseButtonLeft)
	in.Dodge = ebiten.IsKeyPressed(ebiten.KeyK) || ebiten.IsMouseButtonPressed(ebiten.MouseButtonRight)
	in.Clone, in.Restart, in.DebugStep = ebiten.IsKeyPressed(ebiten.KeyC), ebiten.IsKeyPressed(ebiten.KeyEnter), ebiten.IsKeyPressed(ebiten.KeyTab)
	switch {
	case ebiten.IsKeyPressed(ebiten.Key1):
		in.Staff = sim.StaffShort
	case ebiten.IsKeyPressed(ebiten.Key2):
		in.Staff = sim.StaffMedium
	case ebiten.IsKeyPressed(ebiten.Key3):
		in.Staff = sim.StaffLong
	}
	switch {
	case ebiten.IsKeyPressed(ebiten.KeyQ):
		in.Transform = sim.FormBird
	case ebiten.IsKeyPressed(ebiten.KeyE):
		in.Transform = sim.FormTiger
	case ebiten.IsKeyPressed(ebiten.KeyR):
		in.Transform = sim.FormMantis
	case ebiten.IsKeyPressed(ebiten.Key0):
		in.Transform = sim.FormMonkey
	}
	return in
}
func axis(value float64) int8 {
	if value > .35 {
		return 1
	}
	if value < -.35 {
		return -1
	}
	return 0
}

func (g *game) Draw(screen *ebiten.Image) {
	s := g.world.Snapshot()
	g.scene.Clear()
	drawScene(g.scene, s)
	screen.Fill(color.RGBA{R: 8, G: 10, B: 15, A: 255})
	camera := followCamera(s.Player.Pos)
	shake := s.Trauma * 7
	x := -camera.X + math.Sin(float64(s.Tick)*1.91)*shake + s.TraumaDirection.X*s.Trauma*3
	y := -camera.Y + math.Cos(float64(s.Tick)*2.37)*shake + s.TraumaDirection.Y*s.Trauma*3
	op := &ebiten.DrawImageOptions{}
	op.GeoM.Translate(x, y)
	screen.DrawImage(g.scene, op)
	drawHUD(screen, s, camera, g.paused, g.status)
	if s.Debug.Enabled {
		drawDebugHUD(screen, s, camera)
	}
}
func (g *game) Layout(_, _ int) (int, int) { return logicalW, logicalH }

func followCamera(position sim.Vec) sim.Vec {
	return sim.Vec{
		X: math.Max(0, math.Min(position.X-float64(logicalW)/2, sim.ArenaW-float64(logicalW))),
		Y: math.Max(0, math.Min(position.Y-float64(logicalH)/2, sim.ArenaH-float64(logicalH))),
	}
}

func drawScene(screen *ebiten.Image, s sim.RenderSnapshot) {
	screen.Fill(color.RGBA{R: 15, G: 18, B: 24, A: 255})
	drawArena(screen, s.Terrain)
	for _, effect := range s.Effects {
		drawEffect(screen, effect)
	}
	for _, projectile := range s.Projectiles {
		c := color.RGBA{R: 255, G: 180, B: 82, A: 255}
		if projectile.Hazard {
			c = color.RGBA{R: 224, G: 91, B: 187, A: 255}
		}
		vector.DrawFilledCircle(screen, float32(projectile.Pos.X), float32(projectile.Pos.Y), float32(projectile.Radius), c, true)
	}
	for _, clone := range s.Clones {
		drawGlyph(screen, "E", clone.Pos, color.RGBA{R: 110, G: 224, B: 255, A: 255})
		vector.StrokeCircle(screen, float32(clone.Pos.X), float32(clone.Pos.Y), float32(clone.Radius+4), 1, color.RGBA{R: 110, G: 224, B: 255, A: 255}, false)
		if clone.Action == sim.ActionLongCharge {
			vector.StrokeLine(screen, float32(clone.Pos.X), float32(clone.Pos.Y), float32(clone.Pos.X+clone.Aim.X*clone.LongRange), float32(clone.Pos.Y+clone.Aim.Y*clone.LongRange), 2, color.RGBA{R: 110, G: 224, B: 255, A: 210}, true)
		}
		label := fmt.Sprintf("echo %d/%d", max(0, clone.EchoIndex), clone.EchoLength)
		if clone.EchoIndex < 0 {
			label = fmt.Sprintf("echo in %d", -clone.EchoIndex)
		}
		text.Draw(screen, label, basicfont.Face7x13, int(clone.Pos.X)-20, int(clone.Pos.Y)-16, color.RGBA{R: 110, G: 224, B: 255, A: 255})
	}
	for _, enemy := range s.Enemies {
		c := color.RGBA{R: 240, G: 105, B: 110, A: 255}
		if enemy.Flash > 0 {
			c = color.RGBA{R: 255, G: 255, B: 255, A: 255}
		}
		if enemy.WeakPoint > 0 {
			c = color.RGBA{R: 255, G: 238, B: 106, A: 255}
		}
		drawGlyph(screen, "B", enemy.Pos, c)
		drawHealth(screen, enemy.Pos.Add(sim.Vec{X: -22, Y: -enemy.Radius - 14}), 44, enemy.HP, enemy.MaxHP, color.RGBA{R: 227, G: 75, B: 78, A: 255})
		if enemy.Boss != nil && enemy.Boss.Shielded {
			vector.StrokeCircle(screen, float32(enemy.Pos.X), float32(enemy.Pos.Y), float32(enemy.Radius+8), 2, color.RGBA{R: 191, G: 111, B: 245, A: 255}, true)
		}
		if enemy.Boss != nil && enemy.Stagger > 15 {
			text.Draw(screen, "STAGGER", basicfont.Face7x13, int(enemy.Pos.X)-23, int(enemy.Pos.Y)-int(enemy.Radius)-23, color.RGBA{R: 255, G: 238, B: 106, A: 255})
		}
	}
	pc := formColor(s.Player.Form)
	if s.Player.Invulnerable && s.Tick%4 < 2 {
		pc = color.White
	}
	drawPlayerStaff(screen, s.Player)
	drawGlyph(screen, formGlyph(s.Player.Form), s.Player.Pos, pc)
	drawHealth(screen, s.Player.Pos.Add(sim.Vec{X: -20, Y: -28}), 40, s.Player.HP, s.Player.MaxHP, color.RGBA{R: 93, G: 230, B: 136, A: 255})
	if s.Debug.Enabled {
		drawDebugWorld(screen, s)
	}
}

func drawPlayerStaff(screen *ebiten.Image, player sim.PlayerSnapshot) {
	aim := player.Aim
	if aim.LengthSq() == 0 {
		aim = sim.Vec{X: 1}
	}
	if player.Form != sim.FormMonkey {
		vector.StrokeLine(screen, float32(player.Pos.X), float32(player.Pos.Y), float32(player.Pos.X+aim.X*15), float32(player.Pos.Y+aim.Y*15), 1, color.RGBA{R: 126, G: 139, B: 157, A: 180}, true)
		return
	}
	if player.Action == sim.ActionLongCharge {
		forecast := player.Pos.Add(aim.Scale(136))
		drawStaffForecast(screen, player.Pos, forecast, color.RGBA{R: 255, G: 205, B: 92, A: 100})
		end := player.Pos.Add(aim.Scale(player.LongRange))
		vector.StrokeLine(screen, float32(player.Pos.X), float32(player.Pos.Y), float32(end.X), float32(end.Y), 4, color.RGBA{R: 246, G: 171, B: 83, A: 255}, true)
		vector.StrokeCircle(screen, float32(end.X), float32(end.Y), 5, 1, color.RGBA{R: 255, G: 205, B: 92, A: 255}, true)
		return
	}

	rest := staffRestLength(player.Staff)
	if !staffAction(player.Action) {
		drawCarriedStaff(screen, player.Pos, aim, rest, color.RGBA{R: 157, G: 124, B: 84, A: 255}, 3)
		return
	}

	end := player.Pos.Add(aim.Scale(player.AttackRange))
	switch staffPhase(player) {
	case "windup":
		drawCarriedStaff(screen, player.Pos, aim, rest, color.RGBA{R: 246, G: 171, B: 83, A: 255}, 3)
		drawStaffForecast(screen, player.Pos, end, color.RGBA{R: 246, G: 171, B: 83, A: 150})
	case "active":
		vector.StrokeLine(screen, float32(player.Pos.X), float32(player.Pos.Y), float32(end.X), float32(end.Y), float32(max(3, int(player.AttackWidth/3))), color.RGBA{R: 255, G: 240, B: 154, A: 255}, true)
		vector.StrokeCircle(screen, float32(end.X), float32(end.Y), 4, 1, color.RGBA{R: 255, G: 248, B: 205, A: 255}, true)
	case "recovery":
		drawCarriedStaff(screen, player.Pos, aim, rest, color.RGBA{R: 112, G: 125, B: 145, A: 235}, 3)
	}
}

func drawCarriedStaff(screen *ebiten.Image, origin, aim sim.Vec, length float64, c color.Color, width float32) {
	side := sim.Vec{X: -aim.Y, Y: aim.X}
	start := origin.Add(aim.Scale(-length * 0.20)).Add(side.Scale(-length * 0.28))
	end := origin.Add(aim.Scale(-length * 0.08)).Add(side.Scale(length * 0.28))
	vector.StrokeLine(screen, float32(start.X), float32(start.Y), float32(end.X), float32(end.Y), width, c, true)
	vector.DrawFilledCircle(screen, float32(end.X), float32(end.Y), width, c, true)
}

func drawStaffForecast(screen *ebiten.Image, origin, end sim.Vec, c color.Color) {
	delta := end.Sub(origin)
	for segment := 0; segment < 6; segment += 2 {
		start := origin.Add(delta.Scale(float64(segment) / 6))
		finish := origin.Add(delta.Scale(float64(segment+1) / 6))
		vector.StrokeLine(screen, float32(start.X), float32(start.Y), float32(finish.X), float32(finish.Y), 1, c, false)
	}
}

func staffRestLength(staff sim.StaffLength) float64 {
	switch staff {
	case sim.StaffShort:
		return 24
	case sim.StaffLong:
		return 52
	default:
		return 40
	}
}

func staffAction(action sim.Action) bool {
	return action == sim.ActionShort || action == sim.ActionMedium || action == sim.ActionLongRelease
}

func staffPhase(player sim.PlayerSnapshot) string {
	if player.ActionTick < player.AttackStartup {
		return "windup"
	}
	if player.ActionTick < player.AttackStartup+player.AttackActive {
		return "active"
	}
	return "recovery"
}

func drawArena(screen *ebiten.Image, terrain []sim.TerrainSnapshot) {
	for x := 0; x <= logicalW; x += 32 {
		vector.StrokeLine(screen, float32(x), 0, float32(x), logicalH, 1, color.RGBA{R: 25, G: 32, B: 42, A: 255}, false)
	}
	for y := 0; y <= logicalH; y += 32 {
		vector.StrokeLine(screen, 0, float32(y), logicalW, float32(y), 1, color.RGBA{R: 25, G: 32, B: 42, A: 255}, false)
	}
	for _, t := range terrain {
		if t.Kind == sim.TerrainBreakable && t.HP == 0 {
			continue
		}
		c := color.RGBA{R: 82, G: 91, B: 105, A: 255}
		switch t.Kind {
		case sim.TerrainWater:
			c = color.RGBA{R: 38, G: 94, B: 140, A: 255}
		case sim.TerrainPillar:
			c = color.RGBA{R: 112, G: 102, B: 119, A: 255}
		case sim.TerrainBreakable:
			c = color.RGBA{R: 156, G: 109, B: 67, A: 255}
		}
		vector.DrawFilledRect(screen, float32(t.Bounds.X), float32(t.Bounds.Y), float32(t.Bounds.W), float32(t.Bounds.H), c, false)
	}
	vector.StrokeRect(screen, 1, 1, logicalW-2, logicalH-2, 2, color.RGBA{R: 80, G: 90, B: 108, A: 255}, false)
}
func drawEffect(screen *ebiten.Image, e sim.EffectSnapshot) {
	c := color.RGBA{R: 255, G: 232, B: 150, A: 230}
	width := float32(2)
	if e.Kind == sim.EffectHeavyImpact {
		c = color.RGBA{R: 255, G: 132, B: 81, A: 255}
		width = 4
	}
	if e.Kind == sim.EffectStaffTrail || e.Kind == sim.EffectCharge {
		vector.StrokeLine(screen, float32(e.Pos.X), float32(e.Pos.Y), float32(e.Pos.X+e.Direction.X*e.Radius), float32(e.Pos.Y+e.Direction.Y*e.Radius), width, c, true)
		return
	}
	if e.Kind == sim.EffectAfterimage {
		drawGlyph(screen, "@", e.Pos, color.RGBA{R: 164, G: 216, B: 255, A: 140})
		return
	}
	vector.StrokeCircle(screen, float32(e.Pos.X), float32(e.Pos.Y), float32(e.Radius), width, c, true)
	if e.Kind == sim.EffectImpact || e.Kind == sim.EffectHeavyImpact || e.Kind == sim.EffectCounter {
		direction := e.Direction.Normalized()
		if direction.LengthSq() == 0 {
			direction = sim.Vec{X: 1}
		}
		perpendicular := sim.Vec{X: -direction.Y, Y: direction.X}
		for _, sign := range []float64{-1, 1} {
			start := e.Pos.Add(perpendicular.Scale(e.Radius * sign * 0.35))
			end := start.Add(direction.Scale(e.Radius * (0.75 + e.Intensity)))
			vector.StrokeLine(screen, float32(start.X), float32(start.Y), float32(end.X), float32(end.Y), width, c, true)
		}
	}
}
func drawGlyph(screen *ebiten.Image, glyph string, p sim.Vec, c color.Color) {
	text.Draw(screen, glyph, basicfont.Face7x13, int(math.Round(p.X))-4, int(math.Round(p.Y))+5, c)
}
func drawHealth(screen *ebiten.Image, p sim.Vec, w float64, value, maxv int, c color.Color) {
	vector.DrawFilledRect(screen, float32(p.X), float32(p.Y), float32(w), 3, color.RGBA{R: 35, G: 36, B: 43, A: 255}, false)
	if maxv > 0 {
		vector.DrawFilledRect(screen, float32(p.X), float32(p.Y), float32(w*float64(max(0, value))/float64(maxv)), 3, c, false)
	}
}
func formGlyph(f sim.FormID) string {
	switch f {
	case sim.FormBird:
		return "^"
	case sim.FormTiger:
		return "T"
	case sim.FormMantis:
		return "M"
	default:
		return "@"
	}
}
func formColor(f sim.FormID) color.Color {
	switch f {
	case sim.FormBird:
		return color.RGBA{R: 130, G: 217, B: 255, A: 255}
	case sim.FormTiger:
		return color.RGBA{R: 255, G: 168, B: 63, A: 255}
	case sim.FormMantis:
		return color.RGBA{R: 104, G: 245, B: 142, A: 255}
	default:
		return color.RGBA{R: 252, G: 215, B: 85, A: 255}
	}
}
func drawHUD(screen *ebiten.Image, s sim.RenderSnapshot, paused bool, status string) {
	text.Draw(screen, "72  |  WASD move  arrows aim  J attack  K dodge  C Echo", basicfont.Face7x13, 8, 15, color.RGBA{R: 220, G: 224, B: 229, A: 255})
	text.Draw(screen, "1 short  2 medium  3 long hold/release  Q bird  E tiger  R mantis  F1 restart", basicfont.Face7x13, 8, 30, color.RGBA{R: 183, G: 193, B: 207, A: 255})
	text.Draw(screen, fmt.Sprintf("%s | %s", s.Player.Form, staffReadout(s.Player)), basicfont.Face7x13, 8, 342, staffReadoutColor(s.Player))
	for _, e := range s.Enemies {
		if e.Boss != nil {
			text.Draw(screen, "WARDEN — "+e.Boss.PhaseName+" | "+e.Boss.Telegraph, basicfont.Face7x13, 8, 50, color.RGBA{R: 252, G: 171, B: 171, A: 255})
		}
	}
	if paused {
		text.Draw(screen, "PAUSED — P resumes, . steps", basicfont.Face7x13, 220, 180, color.RGBA{R: 255, G: 243, B: 168, A: 255})
	}
	if s.Lost {
		text.Draw(screen, "FALLEN — Enter or F1 retries", basicfont.Face7x13, 210, 180, color.RGBA{R: 255, G: 110, B: 110, A: 255})
	}
	if s.Won {
		text.Draw(screen, "WARDEN BROKEN — F1 replay", basicfont.Face7x13, 220, 180, color.RGBA{R: 127, G: 248, B: 151, A: 255})
	}
	if status != "" {
		text.Draw(screen, status, basicfont.Face7x13, 8, 326, color.RGBA{R: 255, G: 220, B: 132, A: 255})
	}
}

func staffReadout(player sim.PlayerSnapshot) string {
	switch player.Form {
	case sim.FormBird:
		return "BIRD — staff replaced by dive"
	case sim.FormTiger:
		return "TIGER — staff replaced by pounce"
	case sim.FormMantis:
		return "MANTIS — staff replaced by counter"
	}
	if player.Action == sim.ActionLongCharge {
		return fmt.Sprintf("STAFF CHARGING (not active) — long %d/48", player.LongCharge)
	}
	if staffAction(player.Action) {
		phase := staffPhase(player)
		if phase == "windup" {
			return fmt.Sprintf("STAFF WINDUP (not active) — %s %d/%d", player.Staff, player.ActionTick+1, player.AttackStartup+player.AttackActive+player.AttackRecovery)
		}
		if phase == "recovery" {
			return fmt.Sprintf("STAFF RECOVERY (cannot hit) — %s %d/%d", player.Staff, player.ActionTick+1, player.AttackStartup+player.AttackActive+player.AttackRecovery)
		}
		return fmt.Sprintf("STAFF %s — %s %d/%d", strings.ToUpper(phase), player.Staff, player.ActionTick+1, player.AttackStartup+player.AttackActive+player.AttackRecovery)
	}
	if player.Action == sim.ActionDodge {
		return "STAFF NOT ACTIVE — dodging"
	}
	return fmt.Sprintf("STAFF READY (carried) — %s", player.Staff)
}

func staffReadoutColor(player sim.PlayerSnapshot) color.Color {
	if player.Action == sim.ActionLongCharge || (staffAction(player.Action) && staffPhase(player) == "windup") {
		return color.RGBA{R: 246, G: 171, B: 83, A: 255}
	}
	if staffAction(player.Action) && staffPhase(player) == "active" {
		return color.RGBA{R: 255, G: 240, B: 154, A: 255}
	}
	if staffAction(player.Action) && staffPhase(player) == "recovery" {
		return color.RGBA{R: 142, G: 155, B: 176, A: 255}
	}
	return color.RGBA{R: 183, G: 193, B: 207, A: 255}
}
func drawDebug(screen *ebiten.Image, s sim.RenderSnapshot) {
	vector.StrokeCircle(screen, float32(s.Player.Pos.X), float32(s.Player.Pos.Y), float32(s.Player.Radius), 1, color.RGBA{R: 95, G: 247, B: 137, A: 255}, false)
	for _, terrain := range s.Terrain {
		if terrain.Kind == sim.TerrainBreakable && terrain.HP == 0 {
			continue
		}
		vector.StrokeRect(screen, float32(terrain.Bounds.X), float32(terrain.Bounds.Y), float32(terrain.Bounds.W), float32(terrain.Bounds.H), 1, color.RGBA{R: 95, G: 214, B: 247, A: 180}, false)
	}
	if s.Player.AttackRange > 0 {
		end := s.Player.Pos.Add(s.Player.Aim.Scale(s.Player.AttackRange))
		vector.StrokeLine(screen, float32(s.Player.Pos.X), float32(s.Player.Pos.Y), float32(end.X), float32(end.Y), float32(s.Player.AttackWidth*2), color.RGBA{R: 95, G: 214, B: 247, A: 72}, false)
	}
	for _, c := range s.Clones {
		text.Draw(screen, fmt.Sprintf("echo %d/%d m%d,%d a%d,%d atk=%t form=%s", max(0, c.EchoIndex), c.EchoLength, c.ReplayInput.MoveX, c.ReplayInput.MoveY, c.ReplayInput.AimX, c.ReplayInput.AimY, c.ReplayInput.Attack, c.ReplayInput.Transform), basicfont.Face7x13, int(c.Pos.X)-64, int(c.Pos.Y)-16, color.RGBA{R: 110, G: 224, B: 255, A: 255})
	}
	info := fmt.Sprintf("DEBUG aim=(%.0f,%.0f) hitstop=%d slow=%d boss=%s", s.Player.Aim.X, s.Player.Aim.Y, s.Debug.Hitstop, s.Debug.SlowTicks, s.Debug.BossPhase)
	text.Draw(screen, info, basicfont.Face7x13, 8, 356, color.RGBA{R: 100, G: 230, B: 242, A: 255})
}
func main() {
	ebiten.SetWindowSize(logicalW*2, logicalH*2)
	ebiten.SetWindowTitle("72")
	ebiten.SetTPS(sim.TickRate)
	if err := ebiten.RunGame(newGame()); err != nil {
		log.Fatal(err)
	}
}
