package main

import (
	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/render"
)

// commandCanvas lets the established presentation routines submit through a
// CommandFrame while preserving their existing painter order and geometry.
// It retains only the first validation failure because Canvas methods have no
// error return.
type commandCanvas struct {
	frame engine.CommandFrame
	err   error
}

func commandLayer(frame engine.CommandFrame, draw func(engine.Frame)) error {
	canvas := &commandCanvas{frame: frame}
	draw(engine.Frame{Canvas: canvas, Camera: frame.Camera, Tick: frame.Tick, Viewport: frame.Viewport})
	return canvas.err
}

func (c *commandCanvas) record(err error) {
	if c.err == nil {
		c.err = err
	}
}

func (c *commandCanvas) Clear(color engine.Color) {
	c.record(c.frame.Clear(commandColor(color)))
}

func (c *commandCanvas) FillRect(bounds engine.Rect, color engine.Color) {
	c.record(c.frame.FillRect(render.RectDraw{Bounds: commandRect(bounds), Color: commandColor(color)}))
}

func (c *commandCanvas) StrokeRect(bounds engine.Rect, width float64, color engine.Color) {
	c.record(c.frame.StrokeRect(render.RectDraw{Bounds: commandRect(bounds), Width: width, Color: commandColor(color)}))
}

func (c *commandCanvas) FillCircle(center engine.Vec2, radius float64, color engine.Color) {
	c.record(c.frame.FillCircle(render.CircleDraw{Center: commandVec(center), Radius: radius, Color: commandColor(color)}))
}

func (c *commandCanvas) StrokeCircle(center engine.Vec2, radius, width float64, color engine.Color) {
	c.record(c.frame.StrokeCircle(render.CircleDraw{Center: commandVec(center), Radius: radius, Width: width, Color: commandColor(color)}))
}

func (c *commandCanvas) StrokeLine(start, end engine.Vec2, width float64, color engine.Color) {
	c.record(c.frame.StrokeLine(render.LineDraw{Start: commandVec(start), End: commandVec(end), Width: width, Color: commandColor(color)}))
}

func (c *commandCanvas) DrawText(position engine.Vec2, value string, color engine.Color) {
	c.record(c.frame.DrawText(render.TextDraw{Position: commandVec(position), Value: value, Color: commandColor(color)}))
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
