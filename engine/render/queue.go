// Package render defines the backend-neutral high-level 2D rendering contract.
// It owns scene intent; GPU resource management and command submission remain
// backend details.
package render

import "fmt"

// Vec2 is a logical two-dimensional coordinate.
type Vec2 struct{ X, Y float64 }

// Rect is a logical axis-aligned rectangle.
type Rect struct{ X, Y, W, H float64 }

// Color is a non-premultiplied RGBA color.
type Color struct{ R, G, B, A uint8 }

// Space determines whether a command is transformed by Camera.
type Space uint8

const (
	WorldSpace Space = iota
	ScreenSpace
)

// Camera controls the world-to-viewport transform for WorldSpace commands.
type Camera struct {
	Position Vec2
	Viewport Vec2
}

// Texture identifies engine-owned portable image data and a backend-created GPU
// resource. Its ID is opaque to applications.
type Texture struct{ ID uint64 }

// Material identifies optional backend-defined shader/material parameters.
type Material struct {
	Name       string
	Parameters map[string]float64
}

// Sprite describes one textured quad.
type Sprite struct {
	Texture  Texture
	Source   Rect
	Bounds   Rect
	Tint     Color
	Material Material
}

// TileMap describes a tile-grid draw using a single atlas texture. Tiles are
// row-major atlas indices; negative values leave a cell empty.
type TileMap struct {
	Texture  Texture
	Atlas    Vec2
	TileSize Vec2
	Columns  int
	Tiles    []int
	Bounds   Rect
	Tint     Color
}

// CommandKind identifies the payload stored in Command.
type CommandKind uint8

const (
	Clear CommandKind = iota
	SpriteCommand
	TileMapCommand
	FillRect
	StrokeRect
	FillCircle
	StrokeLine
	Text
)

// Command is one high-level 2D draw request. Payload is the corresponding
// public value for Kind; Queue construction validates it at submission time.
type Command struct {
	Kind    CommandKind
	Layer   int
	Space   Space
	Payload any
}

// RectDraw is a filled or stroked rectangle command payload.
type RectDraw struct {
	Bounds Rect
	Width  float64
	Color  Color
}

// CircleDraw is a filled circle command payload.
type CircleDraw struct {
	Center Vec2
	Radius float64
	Color  Color
}

// LineDraw is a stroked line command payload.
type LineDraw struct {
	Start, End Vec2
	Width      float64
	Color      Color
}

// TextDraw is a backend-font text command payload.
type TextDraw struct {
	Position Vec2
	Value    string
	Color    Color
}

// Queue records stable high-level rendering commands for one frame.
type Queue struct{ commands []Command }

// Reset clears all previously recorded commands.
func (q *Queue) Reset() { q.commands = q.commands[:0] }

// Commands returns a copy in submission order.
func (q *Queue) Commands() []Command { return append([]Command(nil), q.commands...) }

// Clear records a full-frame clear. Clear is always screen-space layer zero.
func (q *Queue) Clear(color Color) {
	q.commands = append(q.commands, Command{Kind: Clear, Space: ScreenSpace, Payload: color})
}

// DrawSprite records a textured quad.
func (q *Queue) DrawSprite(layer int, space Space, sprite Sprite) error {
	if sprite.Texture.ID == 0 {
		return fmt.Errorf("sprite texture must not be zero")
	}
	if sprite.Bounds.W <= 0 || sprite.Bounds.H <= 0 {
		return fmt.Errorf("sprite bounds must be positive")
	}
	return q.append(Command{Kind: SpriteCommand, Layer: layer, Space: space, Payload: sprite})
}

// DrawTileMap records a tile-map batch.
func (q *Queue) DrawTileMap(layer int, space Space, tiles TileMap) error {
	if tiles.Texture.ID == 0 || tiles.Atlas.X <= 0 || tiles.Atlas.Y <= 0 || tiles.TileSize.X <= 0 || tiles.TileSize.Y <= 0 || tiles.Columns <= 0 {
		return fmt.Errorf("tile map requires texture, atlas, positive tile size, and columns")
	}
	if len(tiles.Tiles) == 0 {
		return fmt.Errorf("tile map must contain tiles")
	}
	return q.append(Command{Kind: TileMapCommand, Layer: layer, Space: space, Payload: tiles})
}

// FillRect records a filled rectangle.
func (q *Queue) FillRect(layer int, space Space, draw RectDraw) error {
	if draw.Bounds.W <= 0 || draw.Bounds.H <= 0 {
		return fmt.Errorf("rectangle bounds must be positive")
	}
	return q.append(Command{Kind: FillRect, Layer: layer, Space: space, Payload: draw})
}

// StrokeRect records a stroked rectangle.
func (q *Queue) StrokeRect(layer int, space Space, draw RectDraw) error {
	if draw.Bounds.W <= 0 || draw.Bounds.H <= 0 || draw.Width <= 0 {
		return fmt.Errorf("stroked rectangle bounds and width must be positive")
	}
	return q.append(Command{Kind: StrokeRect, Layer: layer, Space: space, Payload: draw})
}

// FillCircle records a filled circle.
func (q *Queue) FillCircle(layer int, space Space, draw CircleDraw) error {
	if draw.Radius <= 0 {
		return fmt.Errorf("circle radius must be positive")
	}
	return q.append(Command{Kind: FillCircle, Layer: layer, Space: space, Payload: draw})
}

// StrokeLine records a line.
func (q *Queue) StrokeLine(layer int, space Space, draw LineDraw) error {
	if draw.Width <= 0 {
		return fmt.Errorf("line width must be positive")
	}
	return q.append(Command{Kind: StrokeLine, Layer: layer, Space: space, Payload: draw})
}

// DrawText records a text request.
func (q *Queue) DrawText(layer int, space Space, draw TextDraw) error {
	if draw.Value == "" {
		return fmt.Errorf("text value must not be empty")
	}
	return q.append(Command{Kind: Text, Layer: layer, Space: space, Payload: draw})
}

func (q *Queue) append(command Command) error {
	if command.Space != WorldSpace && command.Space != ScreenSpace {
		return fmt.Errorf("render command has invalid space %d", command.Space)
	}
	q.commands = append(q.commands, command)
	return nil
}

// Frame is the backend submission payload for one complete render frame.
type Frame struct {
	Camera   Camera
	Queue    *Queue
	Textures *TextureStore
}

// Backend consumes renderer-owned high-level frame intent. Backends must not
// expose their native graphics types through application-facing APIs.
type Backend interface {
	Render(Frame) error
}
