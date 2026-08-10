package engine

import "github.com/gongahkia/72/engine/render"

// Canvas is the backend-neutral immediate drawing surface exposed to games.
// Coordinates are logical pixels.
type Canvas interface {
	Clear(Color)
	FillRect(Rect, Color)
	StrokeRect(Rect, float64, Color)
	FillCircle(Vec2, float64, Color)
	StrokeCircle(Vec2, float64, float64, Color)
	StrokeLine(Vec2, Vec2, float64, Color)
	DrawText(Vec2, string, Color)
}

// CommandCanvas is implemented by backends that consume the high-level 2D
// render contract. Canvas remains available while applications migrate from
// immediate compatibility drawing to command layers.
type CommandCanvas interface {
	Canvas
	RenderCommands(render.Frame) error
}

type transformCanvas struct {
	canvas    Canvas
	translate Vec2
}

func (c transformCanvas) Clear(color Color) { c.canvas.Clear(color) }

func (c transformCanvas) FillRect(rect Rect, color Color) {
	rect.X += c.translate.X
	rect.Y += c.translate.Y
	c.canvas.FillRect(rect, color)
}

func (c transformCanvas) StrokeRect(rect Rect, width float64, color Color) {
	rect.X += c.translate.X
	rect.Y += c.translate.Y
	c.canvas.StrokeRect(rect, width, color)
}

func (c transformCanvas) FillCircle(center Vec2, radius float64, color Color) {
	center.X += c.translate.X
	center.Y += c.translate.Y
	c.canvas.FillCircle(center, radius, color)
}

func (c transformCanvas) StrokeCircle(center Vec2, radius, width float64, color Color) {
	center.X += c.translate.X
	center.Y += c.translate.Y
	c.canvas.StrokeCircle(center, radius, width, color)
}

func (c transformCanvas) StrokeLine(start, end Vec2, width float64, color Color) {
	start.X += c.translate.X
	start.Y += c.translate.Y
	end.X += c.translate.X
	end.Y += c.translate.Y
	c.canvas.StrokeLine(start, end, width, color)
}

func (c transformCanvas) DrawText(position Vec2, value string, color Color) {
	position.X += c.translate.X
	position.Y += c.translate.Y
	c.canvas.DrawText(position, value, color)
}
