package main

import (
	"flag"
	"fmt"
	"image/color"
	"log"
	"math"

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
	world     *sim.World
	replay    *sim.Replay
	scene     *ebiten.Image
	playerArt *playerArt
	seed      uint64
	nextSeed  uint64
	paused    bool
	status    string
}

func newGame() (*game, error) {
	art, err := loadPlayerArt()
	if err != nil {
		return nil, err
	}
	g := &game{seed: runSeed(0x72, 0), nextSeed: 1, scene: ebiten.NewImage(int(sim.ArenaW), int(sim.ArenaH)), playerArt: art}
	g.resetSameSeed()
	return g, nil
}

func (g *game) resetSameSeed() {
	g.world = sim.NewRunWorld(g.seed)
	g.replay = sim.NewReplay(g.seed)
}

func (g *game) resetNextSeed() {
	g.seed = runSeed(0x72, g.nextSeed)
	g.nextSeed++
	g.resetSameSeed()
}

func runSeed(base, index uint64) uint64 {
	seed := base + index*0x9e3779b97f4a7c15
	seed ^= seed >> 30
	seed *= 0xbf58476d1ce4e5b9
	seed ^= seed >> 27
	seed *= 0x94d049bb133111eb
	seed ^= seed >> 31
	if seed == 0 {
		return 1
	}
	return seed
}

func (g *game) Update() error {
	if inpututil.IsKeyJustPressed(ebiten.KeyF1) {
		g.resetSameSeed()
		g.status = fmt.Sprintf("restarted seed %x", g.seed)
		return nil
	}
	if inpututil.IsKeyJustPressed(ebiten.KeyF2) {
		g.resetNextSeed()
		g.status = fmt.Sprintf("new seed %x", g.seed)
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
	if (g.world.Lost || g.world.Won) && inpututil.IsKeyJustPressed(ebiten.KeyEnter) {
		g.resetSameSeed()
		return nil
	}
	if g.paused && !inpututil.IsKeyJustPressed(ebiten.KeyPeriod) {
		return nil
	}
	g.replay.Record(g.world, readInput())
	return nil
}

func readInput() sim.InputFrame {
	in := sim.InputFrame{}
	if ebiten.IsKeyPressed(ebiten.KeyA) {
		in.MoveX--
	}
	if ebiten.IsKeyPressed(ebiten.KeyD) {
		in.MoveX++
	}
	in.Jump = ebiten.IsKeyPressed(ebiten.KeyW) || ebiten.IsKeyPressed(ebiten.KeySpace)
	in.Down = ebiten.IsKeyPressed(ebiten.KeyS)
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
	in.Roll = ebiten.IsKeyPressed(ebiten.KeyShift)
	in.Interact = ebiten.IsKeyPressed(ebiten.KeyE)
	in.Throw = ebiten.IsKeyPressed(ebiten.KeyJ)
	in.DebugStep = ebiten.IsKeyPressed(ebiten.KeyTab)
	if ids := ebiten.AppendGamepadIDs(nil); len(ids) > 0 {
		id := ids[0]
		if in.MoveX == 0 {
			in.MoveX = axis(ebiten.GamepadAxisValue(id, 0))
		}
		if in.AimX == 0 {
			in.AimX = axis(ebiten.GamepadAxisValue(id, 2))
		}
		if in.AimY == 0 {
			in.AimY = axis(ebiten.GamepadAxisValue(id, 3))
		}
		in.Down = in.Down || ebiten.GamepadAxisValue(id, 1) > .35
		in.Jump = in.Jump || ebiten.IsGamepadButtonPressed(id, ebiten.GamepadButton0)
		in.Roll = in.Roll || ebiten.IsGamepadButtonPressed(id, ebiten.GamepadButton1)
		in.Interact = in.Interact || ebiten.IsGamepadButtonPressed(id, ebiten.GamepadButton2)
		in.Throw = in.Throw || ebiten.IsGamepadButtonPressed(id, ebiten.GamepadButton3)
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
	snapshot := g.world.Snapshot()
	g.scene.Clear()
	drawScene(g.scene, snapshot, g.playerArt)
	screen.Fill(color.RGBA{R: 8, G: 10, B: 15, A: 255})
	camera := followCamera(snapshot.Player.Pos)
	shake := snapshot.Trauma * 6
	op := &ebiten.DrawImageOptions{}
	op.GeoM.Translate(-camera.X+math.Sin(float64(snapshot.Tick)*1.9)*shake, -camera.Y+math.Cos(float64(snapshot.Tick)*2.3)*shake)
	screen.DrawImage(g.scene, op)
	drawHUD(screen, snapshot, g.paused, g.status)
	if snapshot.Debug {
		drawDebug(screen, snapshot, camera)
	}
}

func (g *game) Layout(_, _ int) (int, int) { return logicalW, logicalH }

func followCamera(position sim.Vec) sim.Vec {
	return sim.Vec{X: math.Max(0, math.Min(position.X-float64(logicalW)/2, sim.ArenaW-float64(logicalW))), Y: math.Max(0, math.Min(position.Y-float64(logicalH)/2, sim.ArenaH-float64(logicalH)))}
}

func drawScene(screen *ebiten.Image, snapshot sim.RenderSnapshot, playerArt *playerArt) {
	screen.Fill(color.RGBA{R: 14, G: 18, B: 27, A: 255})
	for _, terrain := range snapshot.Terrain {
		terrainColor := color.RGBA{R: 63, G: 70, B: 84, A: 255}
		switch terrain.Kind {
		case sim.TerrainPlatform:
			terrainColor = color.RGBA{R: 116, G: 150, B: 176, A: 255}
		case sim.TerrainBreakable:
			if terrain.HP == 0 {
				continue
			}
			terrainColor = color.RGBA{R: 183, G: 121, B: 78, A: 255}
		case sim.TerrainSpike:
			terrainColor = color.RGBA{R: 208, G: 86, B: 94, A: 255}
		}
		vector.DrawFilledRect(screen, float32(terrain.Bounds.X), float32(terrain.Bounds.Y), float32(terrain.Bounds.W), float32(terrain.Bounds.H), terrainColor, false)
	}
	for _, object := range snapshot.Objects {
		drawObject(screen, object)
	}
	for _, enemy := range snapshot.Enemies {
		drawEnemy(screen, enemy, snapshot.Tick)
	}
	drawImpact(screen, snapshot.Impact, snapshot.Tick)
	p := snapshot.Player
	vector.StrokeLine(screen, float32(p.Pos.X), float32(p.Pos.Y), float32(p.Pos.X+p.Aim.X*18), float32(p.Pos.Y+p.Aim.Y*18), 1, color.RGBA{R: 88, G: 216, B: 251, A: 255}, true)
	playerArt.draw(screen, p, snapshot.Tick)
}

func drawObject(screen *ebiten.Image, object sim.ObjectSnapshot) {
	bounds := sim.Rect{X: object.Pos.X - object.Size.X/2, Y: object.Pos.Y - object.Size.Y/2, W: object.Size.X, H: object.Size.Y}
	c := color.RGBA{R: 182, G: 185, B: 196, A: 255}
	glyph := "?"
	switch object.Kind {
	case sim.ObjectCrate:
		c, glyph = color.RGBA{R: 172, G: 120, B: 69, A: 255}, "C"
	case sim.ObjectRock:
		c, glyph = color.RGBA{R: 146, G: 153, B: 168, A: 255}, "o"
	case sim.ObjectPlate:
		c, glyph = color.RGBA{R: 250, G: 216, B: 101, A: 255}, "="
	case sim.ObjectDoor:
		if object.Active {
			return
		}
		c, glyph = color.RGBA{R: 220, G: 111, B: 89, A: 255}, "|"
	case sim.ObjectExit:
		c, glyph = color.RGBA{R: 108, G: 240, B: 158, A: 255}, ">"
	case sim.ObjectTreasure:
		c, glyph = color.RGBA{R: 255, G: 204, B: 89, A: 255}, "*"
	}
	vector.DrawFilledRect(screen, float32(bounds.X), float32(bounds.Y), float32(bounds.W), float32(bounds.H), c, false)
	drawGlyph(screen, glyph, object.Pos, color.RGBA{R: 15, G: 17, B: 21, A: 255})
}

func drawEnemy(screen *ebiten.Image, enemy sim.EnemySnapshot, tick uint64) {
	bounds := sim.Rect{X: enemy.Pos.X - enemy.Size.X/2, Y: enemy.Pos.Y - enemy.Size.Y/2, W: enemy.Size.X, H: enemy.Size.Y}
	c := color.RGBA{R: 235, G: 116, B: 94, A: 255}
	glyph := ">"
	switch enemy.Archetype {
	case sim.EnemyHopper:
		c, glyph = color.RGBA{R: 139, G: 235, B: 122, A: 255}, "^"
		vector.DrawFilledCircle(screen, float32(enemy.Pos.X), float32(enemy.Pos.Y), float32(enemy.Size.X/2), c, true)
	case sim.EnemyDiver:
		c, glyph = color.RGBA{R: 192, G: 130, B: 246, A: 255}, "v"
		vector.DrawFilledCircle(screen, float32(enemy.Pos.X), float32(enemy.Pos.Y), float32(enemy.Size.X/2), c, true)
	default:
		vector.DrawFilledRect(screen, float32(bounds.X), float32(bounds.Y), float32(bounds.W), float32(bounds.H), c, false)
	}
	if enemy.Flash > 0 {
		vector.StrokeRect(screen, float32(bounds.X-2), float32(bounds.Y-2), float32(bounds.W+4), float32(bounds.H+4), 1, color.RGBA{R: 255, G: 246, B: 204, A: 255}, true)
	}
	if enemy.State == sim.EnemyTelegraph {
		pulse := float32(3 + tick%12/3)
		vector.StrokeCircle(screen, float32(enemy.Pos.X), float32(enemy.Pos.Y), float32(enemy.Size.X/2)+pulse, 1, color.RGBA{R: 255, G: 228, B: 129, A: 255}, true)
	}
	if enemy.State == sim.EnemyCharge || enemy.State == sim.EnemyDive {
		direction := float64(enemy.Facing)
		vector.StrokeLine(screen, float32(enemy.Pos.X-direction*18), float32(enemy.Pos.Y), float32(enemy.Pos.X-direction*5), float32(enemy.Pos.Y), 2, color.RGBA{R: 255, G: 173, B: 111, A: 180}, true)
	}
	drawGlyph(screen, glyph, enemy.Pos, color.RGBA{R: 19, G: 22, B: 31, A: 255})
}

func drawImpact(screen *ebiten.Image, impact sim.ImpactState, tick uint64) {
	if impact.Ticks == 0 {
		return
	}
	strength := impact.Strength * 48
	for index := range 7 {
		angle := float64(index)*math.Pi*2/7 + float64(tick%6)*.11
		start := sim.Vec{X: math.Cos(angle) * strength * .18, Y: math.Sin(angle) * strength * .18}
		end := sim.Vec{X: math.Cos(angle) * strength * .45, Y: math.Sin(angle) * strength * .45}
		vector.StrokeLine(screen, float32(impact.Pos.X+start.X), float32(impact.Pos.Y+start.Y), float32(impact.Pos.X+end.X), float32(impact.Pos.Y+end.Y), 1, color.RGBA{R: 255, G: 220, B: 137, A: 210}, true)
	}
}

func drawGlyph(screen *ebiten.Image, glyph string, position sim.Vec, color color.Color) {
	text.Draw(screen, glyph, basicfont.Face7x13, int(position.X)-3, int(position.Y)+4, color)
}

func drawHUD(screen *ebiten.Image, snapshot sim.RenderSnapshot, paused bool, status string) {
	p := snapshot.Player
	text.Draw(screen, "72 danger playground  |  A/D move  W/space jump  S down  Shift roll", basicfont.Face7x13, 8, 15, color.RGBA{R: 229, G: 233, B: 240, A: 255})
	text.Draw(screen, "E carry/drop  J throw  |  stomp, bait chargers, and take optional treasure", basicfont.Face7x13, 8, 30, color.RGBA{R: 189, G: 207, B: 225, A: 255})
	text.Draw(screen, "F1 same seed  F2 new seed  Enter restart  Tab debug  F6 save replay", basicfont.Face7x13, 8, 45, color.RGBA{R: 189, G: 207, B: 225, A: 255})
	text.Draw(screen, fmt.Sprintf("seed %x  room:%d/%d  treasure:%d  enemies:%d  breaks:%d  %s", snapshot.Seed, snapshot.Stats.RoomsReached, sim.RoomCount, snapshot.Stats.Treasure, snapshot.Stats.EnemiesDefeated, snapshot.Stats.TerrainBroken, p.State), basicfont.Face7x13, 8, 342, color.RGBA{R: 120, G: 236, B: 204, A: 255})
	if p.HeldObjectID >= 0 {
		text.Draw(screen, fmt.Sprintf("holding object %d", p.HeldObjectID), basicfont.Face7x13, 430, 342, color.RGBA{R: 253, G: 213, B: 119, A: 255})
	}
	if paused {
		text.Draw(screen, "PAUSED — P resumes, . steps", basicfont.Face7x13, 210, 180, color.RGBA{R: 255, G: 240, B: 162, A: 255})
	}
	if snapshot.Lost {
		text.Draw(screen, "RESET — Enter or F1 repeats this seed", basicfont.Face7x13, 172, 180, color.RGBA{R: 255, G: 107, B: 108, A: 255})
	}
	if snapshot.Won {
		text.Draw(screen, "RUN COMPLETE — Enter/F1 repeats, F2 varies", basicfont.Face7x13, 156, 180, color.RGBA{R: 113, G: 242, B: 160, A: 255})
	}
	if status != "" {
		text.Draw(screen, status, basicfont.Face7x13, 8, 326, color.RGBA{R: 255, G: 219, B: 137, A: 255})
	}
}

func drawDebug(screen *ebiten.Image, snapshot sim.RenderSnapshot, camera sim.Vec) {
	for _, room := range snapshot.Run.Rooms {
		text.Draw(screen, room.Template.String(), basicfont.Face7x13, int(room.Bounds.X-camera.X)+8, 82, color.RGBA{R: 130, G: 180, B: 255, A: 255})
	}
	for _, object := range snapshot.Objects {
		if object.LinkID != 0 {
			text.Draw(screen, fmt.Sprintf("%s#%d -> %d", object.Kind, object.ID, object.LinkID), basicfont.Face7x13, int(object.Pos.X-camera.X)-26, int(object.Pos.Y-camera.Y)-16, color.RGBA{R: 244, G: 183, B: 116, A: 255})
		}
	}
	p := snapshot.Player
	text.Draw(screen, fmt.Sprintf("state=%s grounded=%t wall=%d/%d ledge=%d roll=%d", p.State, p.Grounded, p.WallDirection, p.WallTicks, p.LedgeTicks, p.RollTicks), basicfont.Face7x13, 8, 62, color.RGBA{R: 239, G: 241, B: 245, A: 255})
}

func aimLabel(aim sim.Vec) string {
	vertical, horizontal := "", ""
	if aim.Y < -.2 {
		vertical = "N"
	} else if aim.Y > .2 {
		vertical = "S"
	}
	if aim.X < -.2 {
		horizontal = "W"
	} else if aim.X > .2 {
		horizontal = "E"
	}
	if vertical+horizontal == "" {
		return "E"
	}
	return vertical + horizontal
}

func main() {
	mode := flag.String("mode", "playtest", "playtest mode")
	flag.Parse()
	if *mode != "playtest" {
		log.Fatalf("unsupported mode %q; use playtest", *mode)
	}
	ebiten.SetWindowSize(logicalW*2, logicalH*2)
	ebiten.SetWindowTitle("72 — danger playground")
	game, err := newGame()
	if err != nil {
		log.Fatal(err)
	}
	if err := ebiten.RunGame(game); err != nil {
		log.Fatal(err)
	}
}
