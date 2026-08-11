package main

import (
	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render"
)

// commandPainter records the established presentation routines into a
// CommandFrame while preserving their painter order and geometry. It retains
// only the first validation failure so scene helpers can remain linear.
type commandPainter struct {
	frame engine.CommandFrame
	err   error
}

func commandLayer(frame engine.CommandFrame, draw func(*commandPainter)) error {
	painter := &commandPainter{frame: frame}
	draw(painter)
	return painter.err
}

func (p *commandPainter) record(err error) {
	if p.err == nil {
		p.err = err
	}
}

func (p *commandPainter) Clear(color engine.Color) {
	p.record(p.frame.Clear(commandColor(color)))
}

func (p *commandPainter) FillRect(bounds engine.Rect, color engine.Color) {
	p.record(p.frame.FillRect(render.RectDraw{Bounds: commandRect(bounds), Color: commandColor(color)}))
}

func (p *commandPainter) StrokeRect(bounds engine.Rect, width float64, color engine.Color) {
	p.record(p.frame.StrokeRect(render.RectDraw{Bounds: commandRect(bounds), Width: width, Color: commandColor(color)}))
}

func (p *commandPainter) FillCircle(center engine.Vec2, radius float64, color engine.Color) {
	p.record(p.frame.FillCircle(render.CircleDraw{Center: commandVec(center), Radius: radius, Color: commandColor(color)}))
}

func (p *commandPainter) StrokeCircle(center engine.Vec2, radius, width float64, color engine.Color) {
	p.record(p.frame.StrokeCircle(render.CircleDraw{Center: commandVec(center), Radius: radius, Width: width, Color: commandColor(color)}))
}

func (p *commandPainter) StrokeLine(start, end engine.Vec2, width float64, color engine.Color) {
	p.record(p.frame.StrokeLine(render.LineDraw{Start: commandVec(start), End: commandVec(end), Width: width, Color: commandColor(color)}))
}

func (p *commandPainter) DrawText(position engine.Vec2, value string, color engine.Color) {
	p.record(p.frame.DrawText(render.TextDraw{Position: commandVec(position), Value: value, Color: commandColor(color)}))
}

func (g *wukongGame) drawDeepBackgroundCommands(frame engine.CommandFrame) error {
	return commandLayer(frame, g.drawDeepBackground)
}

func (g *wukongGame) drawBackgroundCommands(frame engine.CommandFrame) error {
	return commandLayer(frame, g.drawBackground)
}

func (g *wukongGame) drawWorldCommands(frame engine.CommandFrame) error {
	return commandLayer(frame, g.drawWorld)
}

func (g *wukongGame) drawForegroundCommands(frame engine.CommandFrame) error {
	return commandLayer(frame, g.drawForeground)
}

func (g *wukongGame) drawDebugCommands(frame engine.CommandFrame) error {
	return commandLayer(frame, g.drawDebug)
}

func commandVec(value engine.Vec2) render.Vec2 { return render.Vec2{X: value.X, Y: value.Y} }

func commandRect(value engine.Rect) render.Rect {
	return render.Rect{X: value.X, Y: value.Y, W: value.W, H: value.H}
}
