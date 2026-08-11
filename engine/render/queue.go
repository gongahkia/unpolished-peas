// Package render defines the backend-neutral high-level 2D rendering contract.
// It owns scene intent; GPU resource management and command submission remain
// backend details.
package render

import (
	"fmt"
	"math"
)

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

// SpriteTransform applies scale and rotation around a normalized Bounds pivot.
// Zero ScaleX and ScaleY each mean one, preserving pre-transform sprite
// behavior. Negative scale mirrors an axis; Rotation is clockwise radians in
// screen coordinates.
type SpriteTransform struct {
	Origin         Vec2
	ScaleX, ScaleY float64
	Rotation       float64
}

// Sprite describes one textured quad.
type Sprite struct {
	Texture   Texture
	Source    Rect
	Bounds    Rect
	Tint      Color
	Material  Material
	Transform SpriteTransform
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

// TileRange identifies a contiguous row-major tile region. Column and Row are
// zero-based; Columns and Rows are counts. A zero count means no visible tile.
type TileRange struct {
	Column, Row   int
	Columns, Rows int
}

// VisibleRange returns the tile cells whose bounds intersect viewport. Both
// values use the TileMap's coordinate space. Partially visible edge cells are
// retained conservatively. Invalid or empty input returns a zero TileRange;
// Queue validation and renderers remain responsible for reporting invalid maps.
func (tiles TileMap) VisibleRange(viewport Rect) TileRange {
	if tiles.Columns <= 0 || len(tiles.Tiles) == 0 || !finite(tiles.Bounds.X) || !finite(tiles.Bounds.Y) || !finiteVec(tiles.TileSize) || tiles.TileSize.X <= 0 || tiles.TileSize.Y <= 0 || !finiteRect(viewport) || viewport.W <= 0 || viewport.H <= 0 {
		return TileRange{}
	}
	rows := (len(tiles.Tiles) + tiles.Columns - 1) / tiles.Columns
	column := tileRangeStart(viewport.X-tiles.Bounds.X, tiles.TileSize.X, tiles.Columns)
	endColumn := tileRangeEnd(viewport.X+viewport.W-tiles.Bounds.X, tiles.TileSize.X, tiles.Columns)
	row := tileRangeStart(viewport.Y-tiles.Bounds.Y, tiles.TileSize.Y, rows)
	endRow := tileRangeEnd(viewport.Y+viewport.H-tiles.Bounds.Y, tiles.TileSize.Y, rows)
	if endColumn <= column || endRow <= row {
		return TileRange{}
	}
	return TileRange{Column: column, Row: row, Columns: endColumn - column, Rows: endRow - row}
}

func tileRangeStart(value, size float64, maximum int) int {
	if value <= 0 {
		return 0
	}
	if value >= float64(maximum)*size {
		return maximum
	}
	return int(math.Floor(value / size))
}

func tileRangeEnd(value, size float64, maximum int) int {
	if value <= 0 {
		return 0
	}
	if value >= float64(maximum)*size {
		return maximum
	}
	return int(math.Ceil(value / size))
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
	StrokeCircle
	StrokeLine
	Text
)

// Command is one high-level 2D draw request. Payload is the corresponding
// public value for Kind; Queue construction validates it at submission time.
type Command struct {
	Kind    CommandKind
	Layer   int
	Space   Space
	clip    *Rect
	Payload any
}

// Clip returns the effective screen-space clip for this draw. The returned
// rectangle is a value copy; false means the command is not clipped.
func (c Command) Clip() (Rect, bool) {
	if c.clip == nil {
		return Rect{}, false
	}
	return *c.clip, true
}

// RectDraw is a filled or stroked rectangle command payload.
type RectDraw struct {
	Bounds Rect
	Width  float64
	Color  Color
}

// CircleDraw is a filled or stroked circle command payload.
type CircleDraw struct {
	Center Vec2
	Radius float64
	Width  float64
	Color  Color
}

// LineDraw is a stroked line command payload.
type LineDraw struct {
	Start, End Vec2
	Width      float64
	Color      Color
}

// TextDraw is a text command payload. Atlas is optional for compatibility; a
// supplied atlas owns glyph selection, fallback, and portable raster pages.
type TextDraw struct {
	Position Vec2
	Value    string
	Color    Color
	Atlas    *GlyphAtlas
}

// Queue records stable high-level rendering commands for one frame. Clips are
// scoped while recording and resolved to an effective screen-space rectangle on
// each recorded draw, so draw ordering remains independent of clip nesting.
type Queue struct {
	commands []Command
	clips    []Rect
}

// Reset clears all previously recorded commands.
func (q *Queue) Reset() {
	q.commands = q.commands[:0]
	q.clips = q.clips[:0]
}

// Commands returns a copy in submission order.
func (q *Queue) Commands() []Command {
	commands := append([]Command(nil), q.commands...)
	for index := range commands {
		if commands[index].clip == nil {
			continue
		}
		clip := *commands[index].clip
		commands[index].clip = &clip
	}
	return commands
}

// Clear records a full-frame clear. Clear is always screen-space layer zero.
func (q *Queue) Clear(color Color) {
	q.commands = append(q.commands, Command{Kind: Clear, Space: ScreenSpace, Payload: color})
}

// PushClip starts a nested screen-space clip. Each subsequent draw records the
// intersection of this bounds and every active ancestor clip. Clips use target
// logical coordinates and apply equally to world- and screen-space draws.
func (q *Queue) PushClip(bounds Rect) error {
	if !finiteRect(bounds) || bounds.W <= 0 || bounds.H <= 0 {
		return fmt.Errorf("clip bounds must be finite and positive")
	}
	if len(q.clips) > 0 {
		bounds = intersectRects(q.clips[len(q.clips)-1], bounds)
	}
	q.clips = append(q.clips, bounds)
	return nil
}

// PopClip ends the most recently pushed clip.
func (q *Queue) PopClip() error {
	if len(q.clips) == 0 {
		return fmt.Errorf("render clip stack is empty")
	}
	q.clips = q.clips[:len(q.clips)-1]
	return nil
}

// DrawSprite records a textured quad.
func (q *Queue) DrawSprite(layer int, space Space, sprite Sprite) error {
	if sprite.Texture.ID == 0 {
		return fmt.Errorf("sprite texture must not be zero")
	}
	if sprite.Bounds.W <= 0 || sprite.Bounds.H <= 0 {
		return fmt.Errorf("sprite bounds must be positive")
	}
	if !validSpriteTransform(sprite.Transform) {
		return fmt.Errorf("sprite transform must contain finite origin, scale, and rotation")
	}
	return q.append(Command{Kind: SpriteCommand, Layer: layer, Space: space, Payload: sprite})
}

func validSpriteTransform(transform SpriteTransform) bool {
	return finiteSpriteValue(transform.Origin.X) && finiteSpriteValue(transform.Origin.Y) && finiteSpriteValue(transform.ScaleX) && finiteSpriteValue(transform.ScaleY) && finiteSpriteValue(transform.Rotation)
}

func finiteSpriteValue(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

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

// StrokeCircle records a stroked circle.
func (q *Queue) StrokeCircle(layer int, space Space, draw CircleDraw) error {
	if draw.Radius <= 0 || draw.Width <= 0 {
		return fmt.Errorf("stroked circle radius and width must be positive")
	}
	return q.append(Command{Kind: StrokeCircle, Layer: layer, Space: space, Payload: draw})
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
	if len(q.clips) > 0 {
		clip := q.clips[len(q.clips)-1]
		command.clip = &clip
	}
	q.commands = append(q.commands, command)
	return nil
}

func intersectRects(left, right Rect) Rect {
	minimumX, minimumY := math.Max(left.X, right.X), math.Max(left.Y, right.Y)
	maximumX, maximumY := math.Min(left.X+left.W, right.X+right.W), math.Min(left.Y+left.H, right.Y+right.H)
	return Rect{X: minimumX, Y: minimumY, W: math.Max(0, maximumX-minimumX), H: math.Max(0, maximumY-minimumY)}
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func finiteVec(value Vec2) bool { return finite(value.X) && finite(value.Y) }

func finiteRect(value Rect) bool {
	return finite(value.X) && finite(value.Y) && finite(value.W) && finite(value.H)
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
