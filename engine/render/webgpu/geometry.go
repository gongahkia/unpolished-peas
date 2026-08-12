package webgpu

import (
	"encoding/binary"
	"fmt"
	"math"

	"github.com/gongahkia/72/engine/render"
)

func spriteVertices(sprite render.Sprite, textureWidth, textureHeight int, offset render.Vec2, viewportWidth, viewportHeight int) ([]vertex, error) {
	if textureWidth <= 0 || textureHeight <= 0 {
		return nil, fmt.Errorf("sprite texture dimensions must be positive")
	}
	source := sprite.Source
	if source.W == 0 && source.H == 0 {
		source.W, source.H = float64(textureWidth), float64(textureHeight)
	}
	if !finiteRect(source) || source.W <= 0 || source.H <= 0 || source.X < 0 || source.Y < 0 || source.X+source.W > float64(textureWidth) || source.Y+source.H > float64(textureHeight) {
		return nil, fmt.Errorf("sprite source is outside texture %d", sprite.Texture.ID)
	}
	if !finiteRect(sprite.Bounds) || sprite.Bounds.W <= 0 || sprite.Bounds.H <= 0 {
		return nil, fmt.Errorf("sprite bounds must be finite and positive")
	}
	transform, err := normalizedTransform(sprite.Transform)
	if err != nil {
		return nil, err
	}
	if viewportWidth <= 0 || viewportHeight <= 0 {
		return nil, fmt.Errorf("viewport dimensions must be positive")
	}
	bounds := sprite.Bounds
	bounds.X += offset.X
	bounds.Y += offset.Y
	origin := render.Vec2{X: bounds.X + sprite.Transform.Origin.X*bounds.W, Y: bounds.Y + sprite.Transform.Origin.Y*bounds.H}
	points := [4]render.Vec2{
		transformPoint(render.Vec2{X: bounds.X, Y: bounds.Y}, origin, transform),
		transformPoint(render.Vec2{X: bounds.X + bounds.W, Y: bounds.Y}, origin, transform),
		transformPoint(render.Vec2{X: bounds.X + bounds.W, Y: bounds.Y + bounds.H}, origin, transform),
		transformPoint(render.Vec2{X: bounds.X, Y: bounds.Y + bounds.H}, origin, transform),
	}
	u0, v0 := source.X/float64(textureWidth), source.Y/float64(textureHeight)
	u1, v1 := (source.X+source.W)/float64(textureWidth), (source.Y+source.H)/float64(textureHeight)
	tint := tintValue(sprite.Tint)
	quad := [4]vertex{
		vertexAt(points[0], u0, v0, tint, viewportWidth, viewportHeight),
		vertexAt(points[1], u1, v0, tint, viewportWidth, viewportHeight),
		vertexAt(points[2], u1, v1, tint, viewportWidth, viewportHeight),
		vertexAt(points[3], u0, v1, tint, viewportWidth, viewportHeight),
	}
	return []vertex{quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]}, nil
}

type spriteTransform struct{ scaleX, scaleY, rotation float64 }

func normalizedTransform(value render.SpriteTransform) (spriteTransform, error) {
	if !finite(value.Origin.X) || !finite(value.Origin.Y) || !finite(value.ScaleX) || !finite(value.ScaleY) || !finite(value.Rotation) {
		return spriteTransform{}, fmt.Errorf("sprite transform must contain finite origin, scale, and rotation")
	}
	result := spriteTransform{scaleX: value.ScaleX, scaleY: value.ScaleY, rotation: value.Rotation}
	if result.scaleX == 0 {
		result.scaleX = 1
	}
	if result.scaleY == 0 {
		result.scaleY = 1
	}
	return result, nil
}

func transformPoint(point, origin render.Vec2, transform spriteTransform) render.Vec2 {
	x, y := (point.X-origin.X)*transform.scaleX, (point.Y-origin.Y)*transform.scaleY
	cosine, sine := math.Cos(transform.rotation), math.Sin(transform.rotation)
	return render.Vec2{X: origin.X + cosine*x - sine*y, Y: origin.Y + sine*x + cosine*y}
}

func tileVertices(tiles render.TileMap, textureWidth, textureHeight int, offset render.Vec2, viewportWidth, viewportHeight int) ([]vertex, error) {
	if tiles.Columns <= 0 || tiles.TileSize.X <= 0 || tiles.TileSize.Y <= 0 || tiles.Atlas.X <= 0 || tiles.Atlas.Y <= 0 {
		return nil, fmt.Errorf("tile map requires positive atlas, tile size, and columns")
	}
	sourceColumns := int(tiles.Atlas.X / tiles.TileSize.X)
	if sourceColumns <= 0 {
		return nil, fmt.Errorf("tile map atlas is narrower than a tile")
	}
	viewport := render.Rect{X: -offset.X, Y: -offset.Y, W: float64(viewportWidth), H: float64(viewportHeight)}
	visible := tiles.VisibleRange(viewport)
	vertices := make([]vertex, 0, visible.Columns*visible.Rows*6)
	for row := visible.Row; row < visible.Row+visible.Rows; row++ {
		for column := visible.Column; column < visible.Column+visible.Columns; column++ {
			index := row*tiles.Columns + column
			if index < 0 || index >= len(tiles.Tiles) || tiles.Tiles[index] < 0 {
				continue
			}
			tile := tiles.Tiles[index]
			sourceColumn, sourceRow := tile%sourceColumns, tile/sourceColumns
			sprite := render.Sprite{
				Texture: tiles.Texture,
				Source:  render.Rect{X: float64(sourceColumn) * tiles.TileSize.X, Y: float64(sourceRow) * tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Bounds:  render.Rect{X: tiles.Bounds.X + float64(column)*tiles.TileSize.X, Y: tiles.Bounds.Y + float64(row)*tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Tint:    tiles.Tint,
			}
			quad, err := spriteVertices(sprite, textureWidth, textureHeight, offset, viewportWidth, viewportHeight)
			if err != nil {
				return nil, err
			}
			vertices = append(vertices, quad...)
		}
	}
	return vertices, nil
}

func primitiveVertices(command render.Command, offset render.Vec2, viewportWidth, viewportHeight int) ([]vertex, error) {
	toVertices := func(points []render.Vec2, tint render.Color) []vertex {
		result := make([]vertex, 0, len(points))
		for _, point := range points {
			result = append(result, vertexAt(point, 0, 0, tintValue(tint), viewportWidth, viewportHeight))
		}
		return result
	}
	translateRect := func(rect render.Rect) render.Rect {
		rect.X += offset.X
		rect.Y += offset.Y
		return rect
	}
	switch command.Kind {
	case render.FillRect:
		value, ok := command.Payload.(render.RectDraw)
		if !ok {
			return nil, fmt.Errorf("filled rectangle command has payload %T", command.Payload)
		}
		return rectVertices(translateRect(value.Bounds), value.Color, viewportWidth, viewportHeight), nil
	case render.StrokeRect:
		value, ok := command.Payload.(render.RectDraw)
		if !ok {
			return nil, fmt.Errorf("stroked rectangle command has payload %T", command.Payload)
		}
		bounds := translateRect(value.Bounds)
		return append(rectVertices(render.Rect{X: bounds.X, Y: bounds.Y, W: bounds.W, H: value.Width}, value.Color, viewportWidth, viewportHeight), append(rectVertices(render.Rect{X: bounds.X, Y: bounds.Y + bounds.H - value.Width, W: bounds.W, H: value.Width}, value.Color, viewportWidth, viewportHeight), append(rectVertices(render.Rect{X: bounds.X, Y: bounds.Y + value.Width, W: value.Width, H: bounds.H - 2*value.Width}, value.Color, viewportWidth, viewportHeight), rectVertices(render.Rect{X: bounds.X + bounds.W - value.Width, Y: bounds.Y + value.Width, W: value.Width, H: bounds.H - 2*value.Width}, value.Color, viewportWidth, viewportHeight)...)...)...), nil
	case render.FillCircle:
		value, ok := command.Payload.(render.CircleDraw)
		if !ok {
			return nil, fmt.Errorf("filled circle command has payload %T", command.Payload)
		}
		return circleVertices(render.Vec2{X: value.Center.X + offset.X, Y: value.Center.Y + offset.Y}, value.Radius, 0, value.Color, viewportWidth, viewportHeight), nil
	case render.StrokeCircle:
		value, ok := command.Payload.(render.CircleDraw)
		if !ok {
			return nil, fmt.Errorf("stroked circle command has payload %T", command.Payload)
		}
		return circleVertices(render.Vec2{X: value.Center.X + offset.X, Y: value.Center.Y + offset.Y}, value.Radius, value.Width, value.Color, viewportWidth, viewportHeight), nil
	case render.StrokeLine:
		value, ok := command.Payload.(render.LineDraw)
		if !ok {
			return nil, fmt.Errorf("line command has payload %T", command.Payload)
		}
		start := render.Vec2{X: value.Start.X + offset.X, Y: value.Start.Y + offset.Y}
		end := render.Vec2{X: value.End.X + offset.X, Y: value.End.Y + offset.Y}
		dx, dy := end.X-start.X, end.Y-start.Y
		length := math.Hypot(dx, dy)
		if length == 0 {
			return circleVertices(start, value.Width/2, 0, value.Color, viewportWidth, viewportHeight), nil
		}
		half := value.Width / 2
		normal := render.Vec2{X: -dy / length * half, Y: dx / length * half}
		return toVertices([]render.Vec2{{X: start.X + normal.X, Y: start.Y + normal.Y}, {X: end.X + normal.X, Y: end.Y + normal.Y}, {X: end.X - normal.X, Y: end.Y - normal.Y}, {X: start.X + normal.X, Y: start.Y + normal.Y}, {X: end.X - normal.X, Y: end.Y - normal.Y}, {X: start.X - normal.X, Y: start.Y - normal.Y}}, value.Color), nil
	default:
		return nil, fmt.Errorf("unsupported primitive command %d", command.Kind)
	}
}

func rectVertices(bounds render.Rect, tint render.Color, viewportWidth, viewportHeight int) []vertex {
	if bounds.W <= 0 || bounds.H <= 0 {
		return nil
	}
	color := tintValue(tint)
	points := []render.Vec2{{X: bounds.X, Y: bounds.Y}, {X: bounds.X + bounds.W, Y: bounds.Y}, {X: bounds.X + bounds.W, Y: bounds.Y + bounds.H}, {X: bounds.X, Y: bounds.Y}, {X: bounds.X + bounds.W, Y: bounds.Y + bounds.H}, {X: bounds.X, Y: bounds.Y + bounds.H}}
	result := make([]vertex, 0, len(points))
	for _, point := range points {
		result = append(result, vertexAt(point, 0, 0, color, viewportWidth, viewportHeight))
	}
	return result
}

func circleVertices(center render.Vec2, radius, width float64, tint render.Color, viewportWidth, viewportHeight int) []vertex {
	if radius <= 0 {
		return nil
	}
	const segments = 32
	color := tintValue(tint)
	vertices := make([]vertex, 0, segments*6)
	innerRadius := math.Max(0, radius-width)
	if width <= 0 || innerRadius == 0 {
		for index := 0; index < segments; index++ {
			start := circlePoint(center, radius, index, segments)
			end := circlePoint(center, radius, index+1, segments)
			vertices = append(vertices, vertexAt(center, 0, 0, color, viewportWidth, viewportHeight), vertexAt(start, 0, 0, color, viewportWidth, viewportHeight), vertexAt(end, 0, 0, color, viewportWidth, viewportHeight))
		}
		return vertices
	}
	for index := 0; index < segments; index++ {
		outerStart := circlePoint(center, radius, index, segments)
		outerEnd := circlePoint(center, radius, index+1, segments)
		innerStart := circlePoint(center, innerRadius, index, segments)
		innerEnd := circlePoint(center, innerRadius, index+1, segments)
		vertices = append(vertices, vertexAt(outerStart, 0, 0, color, viewportWidth, viewportHeight), vertexAt(outerEnd, 0, 0, color, viewportWidth, viewportHeight), vertexAt(innerEnd, 0, 0, color, viewportWidth, viewportHeight), vertexAt(outerStart, 0, 0, color, viewportWidth, viewportHeight), vertexAt(innerEnd, 0, 0, color, viewportWidth, viewportHeight), vertexAt(innerStart, 0, 0, color, viewportWidth, viewportHeight))
	}
	return vertices
}

func circlePoint(center render.Vec2, radius float64, index, segments int) render.Vec2 {
	angle := float64(index) / float64(segments) * 2 * math.Pi
	return render.Vec2{X: center.X + math.Cos(angle)*radius, Y: center.Y + math.Sin(angle)*radius}
}

func vertexAt(point render.Vec2, u, v float64, tint [4]float32, viewportWidth, viewportHeight int) vertex {
	return vertex{x: float32(point.X/float64(viewportWidth)*2 - 1), y: float32(1 - point.Y/float64(viewportHeight)*2), u: float32(u), v: float32(v), r: tint[0], g: tint[1], b: tint[2], a: tint[3]}
}

func tintValue(value render.Color) [4]float32 {
	return [4]float32{float32(value.R) / 255, float32(value.G) / 255, float32(value.B) / 255, float32(value.A) / 255}
}

func encodeVertices(vertices []vertex) []byte {
	data := make([]byte, len(vertices)*vertexStride)
	for index, value := range vertices {
		offset := index * vertexStride
		binary.LittleEndian.PutUint32(data[offset:], math.Float32bits(value.x))
		binary.LittleEndian.PutUint32(data[offset+4:], math.Float32bits(value.y))
		binary.LittleEndian.PutUint32(data[offset+8:], math.Float32bits(value.u))
		binary.LittleEndian.PutUint32(data[offset+12:], math.Float32bits(value.v))
		binary.LittleEndian.PutUint32(data[offset+16:], math.Float32bits(value.r))
		binary.LittleEndian.PutUint32(data[offset+20:], math.Float32bits(value.g))
		binary.LittleEndian.PutUint32(data[offset+24:], math.Float32bits(value.b))
		binary.LittleEndian.PutUint32(data[offset+28:], math.Float32bits(value.a))
	}
	return data
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func finiteRect(value render.Rect) bool {
	return finite(value.X) && finite(value.Y) && finite(value.W) && finite(value.H)
}
