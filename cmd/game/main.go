package main

import (
	"fmt"
	"image/color"
	"log"
	"math"

	"github.com/gongahkia/journey-roguelite/internal/sim"
	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/inpututil"
	"github.com/hajimehoshi/ebiten/v2/text"
	"github.com/hajimehoshi/ebiten/v2/vector"
	"golang.org/x/image/font/basicfont"
)

const (
	logicalW = 640
	logicalH = 360
)

type game struct {
	world  *sim.World
	paused bool
}

func newGame() *game {
	w := sim.NewWorld(0x5EEDC0DE)
	w.SpawnEnemy(sim.EnemyYaoguai, sim.Vec{X: 140, Y: 100})
	w.SpawnEnemy(sim.EnemyArcher, sim.Vec{X: 500, Y: 100})
	w.SpawnEnemy(sim.EnemyBrute, sim.Vec{X: 510, Y: 265})
	w.SpawnBoss("yellow_wind_sage", "Yellow Wind Sage", sim.Vec{X: 460, Y: 225}, 280)
	return &game{world: w}
}

func (g *game) Update() error {
	if inpututil.IsKeyJustPressed(ebiten.KeyP) {
		g.paused = !g.paused
	}
	if g.paused && !inpututil.IsKeyJustPressed(ebiten.KeyPeriod) {
		return nil
	}
	g.world.Step(readInput())
	return nil
}

func readInput() sim.InputFrame {
	input := sim.InputFrame{}
	if ebiten.IsKeyPressed(ebiten.KeyA) || ebiten.IsKeyPressed(ebiten.KeyArrowLeft) {
		input.MoveX--
	}
	if ebiten.IsKeyPressed(ebiten.KeyD) || ebiten.IsKeyPressed(ebiten.KeyArrowRight) {
		input.MoveX++
	}
	if ebiten.IsKeyPressed(ebiten.KeyW) || ebiten.IsKeyPressed(ebiten.KeyArrowUp) {
		input.MoveY--
	}
	if ebiten.IsKeyPressed(ebiten.KeyS) || ebiten.IsKeyPressed(ebiten.KeyArrowDown) {
		input.MoveY++
	}
	input.Attack = ebiten.IsKeyPressed(ebiten.KeyJ) || ebiten.IsMouseButtonPressed(ebiten.MouseButtonLeft)
	input.Dodge = ebiten.IsKeyPressed(ebiten.KeyK) || ebiten.IsMouseButtonPressed(ebiten.MouseButtonRight)
	input.Clone = ebiten.IsKeyPressed(ebiten.KeyC)
	input.Restart = ebiten.IsKeyPressed(ebiten.KeyEnter)
	input.DebugStep = ebiten.IsKeyPressed(ebiten.KeyTab)
	switch {
	case ebiten.IsKeyPressed(ebiten.Key1):
		input.Staff = sim.StaffShort
	case ebiten.IsKeyPressed(ebiten.Key2):
		input.Staff = sim.StaffMedium
	case ebiten.IsKeyPressed(ebiten.Key3):
		input.Staff = sim.StaffLong
	}
	switch {
	case ebiten.IsKeyPressed(ebiten.KeyQ):
		input.Transform = sim.FormTiger
	case ebiten.IsKeyPressed(ebiten.KeyE):
		input.Transform = sim.FormSparrow
	case ebiten.IsKeyPressed(ebiten.KeyR):
		input.Transform = sim.FormMantis
	case ebiten.IsKeyPressed(ebiten.KeyF):
		input.Transform = sim.FormCicada
	case ebiten.IsKeyPressed(ebiten.KeyG):
		input.Transform = sim.FormGiant
	case ebiten.IsKeyPressed(ebiten.KeyT):
		input.Transform = sim.FormStatue
	case ebiten.IsKeyPressed(ebiten.Key0):
		input.Transform = sim.FormMonkey
	}
	return input
}

func (g *game) Draw(screen *ebiten.Image) {
	snapshot := g.world.Snapshot()
	drawScene(screen, snapshot, g.paused)
}

func (g *game) Layout(_, _ int) (int, int) { return logicalW, logicalH }

func drawScene(screen *ebiten.Image, snapshot sim.RenderSnapshot, paused bool) {
	screen.Fill(color.RGBA{R: 15, G: 18, B: 24, A: 255})
	drawArena(screen)
	for _, effect := range snapshot.Effects {
		drawEffect(screen, effect)
	}
	for _, projectile := range snapshot.Projectiles {
		projectileColor := color.RGBA{R: 255, G: 185, B: 78, A: 255}
		if projectile.Hazard {
			projectileColor = color.RGBA{R: 210, G: 80, B: 180, A: 255}
		}
		vector.DrawFilledCircle(screen, float32(projectile.Pos.X), float32(projectile.Pos.Y), float32(projectile.Radius), projectileColor, true)
	}
	for _, clone := range snapshot.Clones {
		drawGlyph(screen, "@", clone.Pos, color.RGBA{R: 126, G: 222, B: 246, A: 255})
		vector.StrokeLine(screen, float32(clone.Pos.X), float32(clone.Pos.Y), float32(clone.Pos.X+clone.Facing.X*26), float32(clone.Pos.Y+clone.Facing.Y*26), 1.5, color.RGBA{R: 126, G: 222, B: 246, A: 255}, true)
	}
	for _, enemy := range snapshot.Enemies {
		glyph, glyphColor := enemyGlyph(enemy)
		if enemy.Windup > 0 {
			glyphColor = color.RGBA{R: 255, G: 120, B: 80, A: 255}
		}
		drawGlyph(screen, glyph, enemy.Pos, glyphColor)
		drawHealth(screen, enemy.Pos.Add(sim.Vec{X: -16, Y: -enemy.Radius - 13}), 32, enemy.HP, enemy.MaxHP, color.RGBA{R: 218, G: 75, B: 78, A: 255})
		if enemy.Boss != nil && enemy.Boss.Shielded {
			vector.StrokeCircle(screen, float32(enemy.Pos.X), float32(enemy.Pos.Y), float32(enemy.Radius+7), 1.5, color.RGBA{R: 190, G: 110, B: 245, A: 255}, true)
		}
	}
	playerColor := formColor(snapshot.Player.Form)
	if snapshot.Player.Invulnerable && snapshot.Tick%4 < 2 {
		playerColor = color.RGBA{R: 255, G: 255, B: 255, A: 255}
	}
	drawGlyph(screen, formGlyph(snapshot.Player.Form), snapshot.Player.Pos, playerColor)
	drawHealth(screen, snapshot.Player.Pos.Add(sim.Vec{X: -20, Y: -26}), 40, snapshot.Player.HP, snapshot.Player.MaxHP, color.RGBA{R: 90, G: 226, B: 130, A: 255})
	drawHUD(screen, snapshot, paused)
	if snapshot.Debug.Enabled {
		drawDebug(screen, snapshot)
	}
}

func drawArena(screen *ebiten.Image) {
	for x := 0; x <= logicalW; x += 32 {
		vector.StrokeLine(screen, float32(x), 0, float32(x), logicalH, 1, color.RGBA{R: 29, G: 37, B: 48, A: 255}, false)
	}
	for y := 0; y <= logicalH; y += 32 {
		vector.StrokeLine(screen, 0, float32(y), logicalW, float32(y), 1, color.RGBA{R: 29, G: 37, B: 48, A: 255}, false)
	}
	vector.StrokeRect(screen, 1, 1, logicalW-2, logicalH-2, 2, color.RGBA{R: 80, G: 90, B: 108, A: 255}, false)
}

func drawEffect(screen *ebiten.Image, effect sim.EffectSnapshot) {
	switch effect.Kind {
	case sim.EffectStaffTrail:
		vector.StrokeLine(screen, float32(effect.Pos.X), float32(effect.Pos.Y), float32(effect.Pos.X+effect.Direction.X*effect.Radius), float32(effect.Pos.Y+effect.Direction.Y*effect.Radius), 3, color.RGBA{R: 245, G: 210, B: 94, A: 190}, true)
	case sim.EffectTelegraph:
		vector.StrokeCircle(screen, float32(effect.Pos.X), float32(effect.Pos.Y), float32(effect.Radius), 1.5, color.RGBA{R: 248, G: 78, B: 78, A: 210}, true)
	case sim.EffectCounter:
		vector.StrokeCircle(screen, float32(effect.Pos.X), float32(effect.Pos.Y), float32(effect.Radius), 2.5, color.RGBA{R: 120, G: 245, B: 230, A: 255}, true)
	default:
		vector.StrokeCircle(screen, float32(effect.Pos.X), float32(effect.Pos.Y), float32(effect.Radius), 2, color.RGBA{R: 255, G: 235, B: 150, A: 230}, true)
	}
}

func enemyGlyph(enemy sim.EnemySnapshot) (string, color.Color) {
	if enemy.Boss != nil {
		return "B", color.RGBA{R: 240, G: 98, B: 103, A: 255}
	}
	switch enemy.Kind {
	case sim.EnemyBrute:
		return "G", color.RGBA{R: 235, G: 157, B: 73, A: 255}
	case sim.EnemyArcher:
		return "*", color.RGBA{R: 216, G: 109, B: 214, A: 255}
	default:
		return "g", color.RGBA{R: 228, G: 110, B: 111, A: 255}
	}
}

func formGlyph(form sim.FormID) string {
	switch form {
	case sim.FormTiger:
		return "T"
	case sim.FormSparrow:
		return "^"
	case sim.FormMantis:
		return "M"
	case sim.FormCicada:
		return "c"
	case sim.FormGiant:
		return "O"
	case sim.FormStatue:
		return "#"
	default:
		return "@"
	}
}

func formColor(form sim.FormID) color.Color {
	switch form {
	case sim.FormTiger:
		return color.RGBA{R: 255, G: 168, B: 63, A: 255}
	case sim.FormSparrow:
		return color.RGBA{R: 130, G: 217, B: 255, A: 255}
	case sim.FormMantis:
		return color.RGBA{R: 104, G: 245, B: 142, A: 255}
	case sim.FormCicada:
		return color.RGBA{R: 219, G: 137, B: 250, A: 255}
	case sim.FormGiant:
		return color.RGBA{R: 245, G: 112, B: 91, A: 255}
	case sim.FormStatue:
		return color.RGBA{R: 172, G: 179, B: 188, A: 255}
	default:
		return color.RGBA{R: 252, G: 215, B: 85, A: 255}
	}
}

func drawGlyph(screen *ebiten.Image, glyph string, position sim.Vec, glyphColor color.Color) {
	text.Draw(screen, glyph, basicfont.Face7x13, int(math.Round(position.X))-4, int(math.Round(position.Y))+5, glyphColor)
}

func drawHealth(screen *ebiten.Image, position sim.Vec, width float64, value, maximum int, fill color.Color) {
	vector.DrawFilledRect(screen, float32(position.X), float32(position.Y), float32(width), 3, color.RGBA{R: 35, G: 36, B: 43, A: 255}, false)
	if maximum > 0 {
		vector.DrawFilledRect(screen, float32(position.X), float32(position.Y), float32(width*float64(max(0, value))/float64(maximum)), 3, fill, false)
	}
}

func drawHUD(screen *ebiten.Image, snapshot sim.RenderSnapshot, paused bool) {
	text.Draw(screen, "JOURNEY OF THE CLOUD-BORN  |  J strike  K cloud dodge  C hair clone", basicfont.Face7x13, 8, 15, color.RGBA{R: 220, G: 224, B: 229, A: 255})
	status := fmt.Sprintf("form: %s  staff: %s  action: %s  tick: %d", snapshot.Player.Form, snapshot.Player.Staff, snapshot.Player.Action, snapshot.Tick)
	text.Draw(screen, status, basicfont.Face7x13, 8, 339, color.RGBA{R: 183, G: 193, B: 207, A: 255})
	for _, enemy := range snapshot.Enemies {
		if enemy.Boss != nil {
			boss := fmt.Sprintf("%s — %s", enemy.Name, enemy.Boss.PhaseName)
			if enemy.Boss.Telegraph != "" {
				boss += " | " + enemy.Boss.Telegraph
			}
			text.Draw(screen, boss, basicfont.Face7x13, 8, 32, color.RGBA{R: 252, G: 171, B: 171, A: 255})
		}
	}
	if paused {
		text.Draw(screen, "PAUSED — P resumes, . advances one tick", basicfont.Face7x13, 190, 177, color.RGBA{R: 255, G: 243, B: 168, A: 255})
	}
	if snapshot.Lost {
		text.Draw(screen, "FALLEN — press Enter to restart", basicfont.Face7x13, 215, 180, color.RGBA{R: 255, G: 110, B: 110, A: 255})
	}
	if snapshot.Won {
		text.Draw(screen, "ENCOUNTER CLEARED", basicfont.Face7x13, 240, 180, color.RGBA{R: 127, G: 248, B: 151, A: 255})
	}
}

func drawDebug(screen *ebiten.Image, snapshot sim.RenderSnapshot) {
	for _, enemy := range snapshot.Enemies {
		vector.StrokeCircle(screen, float32(enemy.Pos.X), float32(enemy.Pos.Y), float32(enemy.Radius), 1, color.RGBA{R: 80, G: 225, B: 255, A: 255}, false)
		vector.StrokeLine(screen, float32(enemy.Pos.X), float32(enemy.Pos.Y), float32(enemy.Pos.X+enemy.Velocity.X*6), float32(enemy.Pos.Y+enemy.Velocity.Y*6), 1, color.RGBA{R: 80, G: 225, B: 255, A: 255}, false)
	}
	vector.StrokeCircle(screen, float32(snapshot.Player.Pos.X), float32(snapshot.Player.Pos.Y), float32(snapshot.Player.Radius), 1, color.RGBA{R: 95, G: 247, B: 137, A: 255}, false)
	info := fmt.Sprintf("DEBUG  seed=%x rng=%x hitstop=%d boss=%s", snapshot.Seed, snapshot.Debug.RNG, snapshot.Debug.Hitstop, snapshot.Debug.BossPhase)
	text.Draw(screen, info, basicfont.Face7x13, 8, 354, color.RGBA{R: 100, G: 230, B: 242, A: 255})
}

func main() {
	ebiten.SetWindowSize(logicalW*2, logicalH*2)
	ebiten.SetWindowTitle("Journey of the Cloud-Born")
	ebiten.SetTPS(sim.TickRate)
	if err := ebiten.RunGame(newGame()); err != nil {
		log.Fatal(err)
	}
}
