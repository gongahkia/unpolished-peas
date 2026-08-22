package main

import (
	"fmt"
	"math"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render"
	"github.com/gongahkia/72/example/wukong/internal/sim"
)

func followCamera(position sim.Vec) sim.Vec {
	return sim.Vec{
		X: math.Max(0, math.Min(position.X-float64(logicalW)/2, sim.ArenaW-float64(logicalW))),
		Y: math.Max(0, math.Min(position.Y-float64(logicalH)/2, sim.ArenaH-float64(logicalH))),
	}
}

func (g *wukongGame) drawWorld(canvas *commandPainter) { drawScene(canvas, g.snapshot) }

func drawScene(canvas *commandPainter, snapshot sim.RenderSnapshot) {
	for _, terrain := range snapshot.Terrain {
		terrainColor := rgba(63, 70, 84, 255)
		switch terrain.Kind {
		case sim.TerrainPlatform:
			terrainColor = rgba(116, 150, 176, 255)
		case sim.TerrainBreakable:
			if terrain.HP == 0 {
				continue
			}
			terrainColor = rgba(183, 121, 78, 255)
		case sim.TerrainSpike:
			terrainColor = rgba(208, 86, 94, 255)
		}
		canvas.FillRect(rect(terrain.Bounds), terrainColor)
	}
	for _, object := range snapshot.Objects {
		drawObject(canvas, object)
	}
	for _, enemy := range snapshot.Enemies {
		drawEnemy(canvas, enemy, snapshot.Tick)
	}
	drawImpact(canvas, snapshot.Impact, snapshot.Tick)
	p := snapshot.Player
	canvas.StrokeLine(vec(p.Pos), vec(p.Pos.Add(p.Aim.Scale(18))), 1, rgba(88, 216, 251, 255))
}

func drawObject(canvas *commandPainter, object sim.ObjectSnapshot) {
	bounds := sim.Rect{X: object.Pos.X - object.Size.X/2, Y: object.Pos.Y - object.Size.Y/2, W: object.Size.X, H: object.Size.Y}
	c := rgba(182, 185, 196, 255)
	glyph := "?"
	switch object.Kind {
	case sim.ObjectCrate:
		c, glyph = rgba(172, 120, 69, 255), "C"
	case sim.ObjectRock:
		c, glyph = rgba(146, 153, 168, 255), "o"
	case sim.ObjectPlate:
		c, glyph = rgba(250, 216, 101, 255), "="
	case sim.ObjectDoor:
		if object.Active {
			return
		}
		c, glyph = rgba(220, 111, 89, 255), "|"
	case sim.ObjectExit:
		c, glyph = rgba(108, 240, 158, 255), ">"
	case sim.ObjectTreasure:
		c, glyph = rgba(255, 204, 89, 255), "*"
	}
	canvas.FillRect(rect(bounds), c)
	drawGlyph(canvas, glyph, object.Pos, rgba(15, 17, 21, 255))
}

func drawEnemy(canvas *commandPainter, enemy sim.EnemySnapshot, tick uint64) {
	bounds := sim.Rect{X: enemy.Pos.X - enemy.Size.X/2, Y: enemy.Pos.Y - enemy.Size.Y/2, W: enemy.Size.X, H: enemy.Size.Y}
	c := rgba(235, 116, 94, 255)
	glyph := ">"
	switch enemy.Archetype {
	case sim.EnemyHopper:
		c, glyph = rgba(139, 235, 122, 255), "^"
		canvas.FillCircle(vec(enemy.Pos), enemy.Size.X/2, c)
	case sim.EnemyDiver:
		c, glyph = rgba(192, 130, 246, 255), "v"
		canvas.FillCircle(vec(enemy.Pos), enemy.Size.X/2, c)
	default:
		canvas.FillRect(rect(bounds), c)
	}
	if enemy.Flash > 0 {
		canvas.StrokeRect(engine.Rect{X: bounds.X - 2, Y: bounds.Y - 2, W: bounds.W + 4, H: bounds.H + 4}, 1, rgba(255, 246, 204, 255))
	}
	if enemy.State == sim.EnemyTelegraph {
		pulse := 3 + float64(tick%12/3)
		canvas.StrokeCircle(vec(enemy.Pos), enemy.Size.X/2+pulse, 1, rgba(255, 228, 129, 255))
	}
	if enemy.State == sim.EnemyCharge || enemy.State == sim.EnemyDive {
		direction := float64(enemy.Facing)
		canvas.StrokeLine(engine.Vec2{X: enemy.Pos.X - direction*18, Y: enemy.Pos.Y}, engine.Vec2{X: enemy.Pos.X - direction*5, Y: enemy.Pos.Y}, 2, rgba(255, 173, 111, 180))
	}
	drawGlyph(canvas, glyph, enemy.Pos, rgba(19, 22, 31, 255))
}

func drawImpact(canvas *commandPainter, impact sim.ImpactState, tick uint64) {
	if impact.Ticks == 0 {
		return
	}
	strength := impact.Strength * 48
	for index := range 7 {
		angle := float64(index)*math.Pi*2/7 + float64(tick%6)*.11
		start := sim.Vec{X: math.Cos(angle) * strength * .18, Y: math.Sin(angle) * strength * .18}
		end := sim.Vec{X: math.Cos(angle) * strength * .45, Y: math.Sin(angle) * strength * .45}
		canvas.StrokeLine(vec(impact.Pos.Add(start)), vec(impact.Pos.Add(end)), 1, rgba(255, 220, 137, 210))
	}
}

func drawGlyph(canvas *commandPainter, glyph string, position sim.Vec, color engine.Color) {
	canvas.DrawText(engine.Vec2{X: position.X - 3, Y: position.Y + 4}, glyph, color)
}

func (g *wukongGame) drawHUDCommands(frame engine.CommandFrame) error {
	snapshot := g.snapshot
	p := snapshot.Player
	drawText := func(position engine.Vec2, value string, color engine.Color) error {
		return frame.DrawText(render.TextDraw{Position: render.Vec2{X: position.X, Y: position.Y}, Value: value, Color: commandColor(color)})
	}
	if err := drawText(engine.Vec2{X: 8, Y: 15}, "Wukong danger playground  |  A/D move  W/space jump  S down  Shift roll", rgba(229, 233, 240, 255)); err != nil {
		return err
	}
	if err := drawText(engine.Vec2{X: 8, Y: 30}, "E carry/drop  J throw  |  stomp, bait chargers, and take optional treasure", rgba(189, 207, 225, 255)); err != nil {
		return err
	}
	if err := drawText(engine.Vec2{X: 8, Y: 45}, "F1 same seed  F2 new seed  Enter restart  Tab debug  F6 save replay", rgba(189, 207, 225, 255)); err != nil {
		return err
	}
	if err := drawText(engine.Vec2{X: 8, Y: 342}, fmt.Sprintf("seed %x  room:%d/%d  treasure:%d  enemies:%d  breaks:%d  %s", snapshot.Seed, snapshot.Stats.RoomsReached, sim.RoomCount, snapshot.Stats.Treasure, snapshot.Stats.EnemiesDefeated, snapshot.Stats.TerrainBroken, p.State), rgba(120, 236, 204, 255)); err != nil {
		return err
	}
	if p.HeldObjectID >= 0 {
		if err := drawText(engine.Vec2{X: 430, Y: 342}, fmt.Sprintf("holding object %d", p.HeldObjectID), rgba(253, 213, 119, 255)); err != nil {
			return err
		}
	}
	if g.paused {
		if err := drawText(engine.Vec2{X: 210, Y: 180}, "PAUSED — P resumes, . steps", rgba(255, 240, 162, 255)); err != nil {
			return err
		}
	}
	if snapshot.Lost {
		if err := drawText(engine.Vec2{X: 172, Y: 180}, "RESET — Enter or F1 repeats this seed", rgba(255, 107, 108, 255)); err != nil {
			return err
		}
	}
	if snapshot.Won {
		if err := drawText(engine.Vec2{X: 156, Y: 180}, "RUN COMPLETE — Enter/F1 repeats, F2 varies", rgba(113, 242, 160, 255)); err != nil {
			return err
		}
	}
	if g.status != "" {
		if err := drawText(engine.Vec2{X: 8, Y: 326}, g.status, rgba(255, 219, 137, 255)); err != nil {
			return err
		}
	}
	return nil
}

func (g *wukongGame) drawDebug(canvas *commandPainter) {
	if !g.snapshot.Debug {
		return
	}
	camera := canvas.frame.Camera.Position()
	for _, room := range g.snapshot.Run.Rooms {
		canvas.DrawText(engine.Vec2{X: room.Bounds.X - camera.X + 8, Y: 82}, room.Template.String(), rgba(130, 180, 255, 255))
	}
	for _, object := range g.snapshot.Objects {
		if object.LinkID != 0 {
			canvas.DrawText(engine.Vec2{X: object.Pos.X - camera.X - 26, Y: object.Pos.Y - camera.Y - 16}, fmt.Sprintf("%s#%d -> %d", object.Kind, object.ID, object.LinkID), rgba(244, 183, 116, 255))
		}
	}
	p := g.snapshot.Player
	canvas.DrawText(engine.Vec2{X: 8, Y: 62}, fmt.Sprintf("state=%s grounded=%t wall=%d/%d ledge=%d roll=%d", p.State, p.Grounded, p.WallDirection, p.WallTicks, p.LedgeTicks, p.RollTicks), rgba(239, 241, 245, 255))
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

func vec(value sim.Vec) engine.Vec2 { return engine.Vec2{X: value.X, Y: value.Y} }

func rect(value sim.Rect) engine.Rect {
	return engine.Rect{X: value.X, Y: value.Y, W: value.W, H: value.H}
}

func rgba(red, green, blue, alpha uint8) engine.Color {
	return engine.Color{R: red, G: green, B: blue, A: alpha}
}

func commandColor(value engine.Color) render.Color {
	return render.Color{R: value.R, G: value.G, B: value.B, A: value.A}
}
