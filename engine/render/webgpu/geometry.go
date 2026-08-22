package webgpu

import (
	"encoding/binary"
	"fmt"
	"math"

	"github.com/gongahkia/72/engine/render"
)

type cameraTransform struct {
	position render.Vec2
	offset   render.Vec2
	center   render.Vec2
	zoom     float64
}

func newCameraTransform(camera render.Camera, space render.Space) (cameraTransform, error) {
	if space == render.ScreenSpace {
		return cameraTransform{zoom: 1}, nil
	}
	if space != render.WorldSpace {
		return cameraTransform{}, fmt.Errorf("render command has invalid space %d", space)
	}
	if !finite(camera.Position.X) || !finite(camera.Position.Y) || !finite(camera.Offset.X) || !finite(camera.Offset.Y) || !finite(camera.Viewport.X) || !finite(camera.Viewport.Y) {
		return cameraTransform{}, fmt.Errorf("render camera position, offset, and viewport must be finite")
	}
	zoom := camera.Zoom
	if zoom == 0 {
		zoom = 1
	}
	if !finite(zoom) || zoom <= 0 {
		return cameraTransform{}, fmt.Errorf("render camera zoom must be finite and positive")
	}
	return cameraTransform{position: camera.Position, offset: camera.Offset, center: render.Vec2{X: camera.Viewport.X / 2, Y: camera.Viewport.Y / 2}, zoom: zoom}, nil
}

func (t cameraTransform) point(value render.Vec2) render.Vec2 {
	return render.Vec2{X: t.center.X + (value.X-t.position.X-t.center.X)*t.zoom + t.offset.X, Y: t.center.Y + (value.Y-t.position.Y-t.center.Y)*t.zoom + t.offset.Y}
}

func (t cameraTransform) rect(value render.Rect) render.Rect {
	point := t.point(render.Vec2{X: value.X, Y: value.Y})
	return render.Rect{X: point.X, Y: point.Y, W: value.W * t.zoom, H: value.H * t.zoom}
}

func (t cameraTransform) inverseRect(value render.Rect) render.Rect {
	return render.Rect{X: t.position.X + t.center.X + (value.X-t.center.X-t.offset.X)/t.zoom, Y: t.position.Y + t.center.Y + (value.Y-t.center.Y-t.offset.Y)/t.zoom, W: value.W / t.zoom, H: value.H / t.zoom}
}

func spriteVertices(sprite render.Sprite, textureWidth, textureHeight int, transform cameraTransform, viewportWidth, viewportHeight int) ([]vertex, error) {
	quad, err := spriteQuad(sprite, textureWidth, textureHeight, transform, viewportWidth, viewportHeight)
	if err != nil {
		return nil, err
	}
	return []vertex{quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]}, nil
}

func spriteInstance(sprite render.Sprite, textureWidth, textureHeight int, transform cameraTransform, viewportWidth, viewportHeight int) (spriteInstanceData, error) {
	quad, err := spriteQuad(sprite, textureWidth, textureHeight, transform, viewportWidth, viewportHeight)
	if err != nil {
		return spriteInstanceData{}, err
	}
	return spriteInstanceData{
		points01:  [4]float32{quad[0].x, quad[0].y, quad[1].x, quad[1].y},
		points23:  [4]float32{quad[2].x, quad[2].y, quad[3].x, quad[3].y},
		texcoords: [4]float32{quad[0].u, quad[0].v, quad[2].u, quad[2].v},
		tint:      [4]float32{quad[0].r, quad[0].g, quad[0].b, quad[0].a},
	}, nil
}

func spriteQuad(sprite render.Sprite, textureWidth, textureHeight int, view cameraTransform, viewportWidth, viewportHeight int) ([4]vertex, error) {
	if textureWidth <= 0 || textureHeight <= 0 {
		return [4]vertex{}, fmt.Errorf("sprite texture dimensions must be positive")
	}
	source := sprite.Source
	if source.W == 0 && source.H == 0 {
		source.W, source.H = float64(textureWidth), float64(textureHeight)
	}
	if !finiteRect(source) || source.W <= 0 || source.H <= 0 || source.X < 0 || source.Y < 0 || source.X+source.W > float64(textureWidth) || source.Y+source.H > float64(textureHeight) {
		return [4]vertex{}, fmt.Errorf("sprite source is outside texture %d", sprite.Texture.ID)
	}
	if !finiteRect(sprite.Bounds) || sprite.Bounds.W <= 0 || sprite.Bounds.H <= 0 {
		return [4]vertex{}, fmt.Errorf("sprite bounds must be finite and positive")
	}
	transform, err := normalizedTransform(sprite.Transform)
	if err != nil {
		return [4]vertex{}, err
	}
	if viewportWidth <= 0 || viewportHeight <= 0 {
		return [4]vertex{}, fmt.Errorf("viewport dimensions must be positive")
	}
	bounds := sprite.Bounds
	origin := render.Vec2{X: bounds.X + sprite.Transform.Origin.X*bounds.W, Y: bounds.Y + sprite.Transform.Origin.Y*bounds.H}
	points := [4]render.Vec2{
		view.point(transformPoint(render.Vec2{X: bounds.X, Y: bounds.Y}, origin, transform)),
		view.point(transformPoint(render.Vec2{X: bounds.X + bounds.W, Y: bounds.Y}, origin, transform)),
		view.point(transformPoint(render.Vec2{X: bounds.X + bounds.W, Y: bounds.Y + bounds.H}, origin, transform)),
		view.point(transformPoint(render.Vec2{X: bounds.X, Y: bounds.Y + bounds.H}, origin, transform)),
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
	return quad, nil
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

func tileInstances(tiles render.TileMap, textureWidth, textureHeight int, transform cameraTransform, viewportWidth, viewportHeight int) ([]spriteInstanceData, error) {
	if !finiteRect(tiles.Bounds) || !finite(tiles.Atlas.X) || !finite(tiles.Atlas.Y) || !finite(tiles.TileSize.X) || !finite(tiles.TileSize.Y) || tiles.Columns <= 0 || tiles.TileSize.X <= 0 || tiles.TileSize.Y <= 0 || tiles.Atlas.X <= 0 || tiles.Atlas.Y <= 0 {
		return nil, fmt.Errorf("tile map requires finite bounds, positive atlas, tile size, and columns")
	}
	sourceColumns := int(tiles.Atlas.X / tiles.TileSize.X)
	if sourceColumns <= 0 {
		return nil, fmt.Errorf("tile map atlas is narrower than a tile")
	}
	viewport := transform.inverseRect(render.Rect{W: float64(viewportWidth), H: float64(viewportHeight)})
	visible := tiles.VisibleRange(viewport)
	instances := make([]spriteInstanceData, 0, visible.Columns*visible.Rows)
	for row := visible.Row; row < visible.Row+visible.Rows; row++ {
		for column := visible.Column; column < visible.Column+visible.Columns; column++ {
			index := row*tiles.Columns + column
			if index < 0 || index >= len(tiles.Tiles) || tiles.Tiles[index] < 0 {
				continue
			}
			tile := tiles.Tiles[index]
			sourceColumn, sourceRow := tile%sourceColumns, tile/sourceColumns
			sprite := render.Sprite{
				Texture:  tiles.Texture,
				Source:   render.Rect{X: float64(sourceColumn) * tiles.TileSize.X, Y: float64(sourceRow) * tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Bounds:   render.Rect{X: tiles.Bounds.X + float64(column)*tiles.TileSize.X, Y: tiles.Bounds.Y + float64(row)*tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Tint:     tiles.Tint,
				Sampling: tiles.Sampling,
				Blend:    tiles.Blend,
			}
			instance, err := spriteInstance(sprite, textureWidth, textureHeight, transform, viewportWidth, viewportHeight)
			if err != nil {
				return nil, err
			}
			instances = append(instances, instance)
		}
	}
	return instances, nil
}

func primitiveVertices(command render.Command, transform cameraTransform, viewportWidth, viewportHeight int) ([]vertex, error) {
	toVertices := func(points []render.Vec2, tint render.Color) []vertex {
		result := make([]vertex, 0, len(points))
		for _, point := range points {
			result = append(result, vertexAt(transform.point(point), 0, 0, tintValue(tint), viewportWidth, viewportHeight))
		}
		return result
	}
	switch command.Kind {
	case render.FillRect:
		value, ok := command.Payload.(render.RectDraw)
		if !ok {
			return nil, fmt.Errorf("filled rectangle command has payload %T", command.Payload)
		}
		if !finiteRect(value.Bounds) || value.Bounds.W <= 0 || value.Bounds.H <= 0 {
			return nil, fmt.Errorf("filled rectangle bounds must be finite and positive")
		}
		return rectVertices(transform.rect(value.Bounds), value.Color, viewportWidth, viewportHeight), nil
	case render.StrokeRect:
		value, ok := command.Payload.(render.RectDraw)
		if !ok {
			return nil, fmt.Errorf("stroked rectangle command has payload %T", command.Payload)
		}
		if !finiteRect(value.Bounds) || !finite(value.Width) || value.Bounds.W <= 0 || value.Bounds.H <= 0 || value.Width <= 0 {
			return nil, fmt.Errorf("stroked rectangle bounds and width must be finite and positive")
		}
		bounds := transform.rect(value.Bounds)
		width := value.Width * transform.zoom
		if width*2 >= bounds.W || width*2 >= bounds.H {
			return rectVertices(bounds, value.Color, viewportWidth, viewportHeight), nil
		}
		vertices := rectVertices(render.Rect{X: bounds.X, Y: bounds.Y, W: bounds.W, H: width}, value.Color, viewportWidth, viewportHeight)
		vertices = append(vertices, rectVertices(render.Rect{X: bounds.X, Y: bounds.Y + bounds.H - width, W: bounds.W, H: width}, value.Color, viewportWidth, viewportHeight)...)
		vertices = append(vertices, rectVertices(render.Rect{X: bounds.X, Y: bounds.Y + width, W: width, H: bounds.H - 2*width}, value.Color, viewportWidth, viewportHeight)...)
		vertices = append(vertices, rectVertices(render.Rect{X: bounds.X + bounds.W - width, Y: bounds.Y + width, W: width, H: bounds.H - 2*width}, value.Color, viewportWidth, viewportHeight)...)
		return vertices, nil
	case render.FillCircle:
		value, ok := command.Payload.(render.CircleDraw)
		if !ok {
			return nil, fmt.Errorf("filled circle command has payload %T", command.Payload)
		}
		if !finite(value.Center.X) || !finite(value.Center.Y) || !finite(value.Radius) || value.Radius <= 0 {
			return nil, fmt.Errorf("filled circle center and radius must be finite and positive")
		}
		return circleVertices(transform.point(value.Center), value.Radius*transform.zoom, 0, value.Color, viewportWidth, viewportHeight), nil
	case render.StrokeCircle:
		value, ok := command.Payload.(render.CircleDraw)
		if !ok {
			return nil, fmt.Errorf("stroked circle command has payload %T", command.Payload)
		}
		if !finite(value.Center.X) || !finite(value.Center.Y) || !finite(value.Radius) || !finite(value.Width) || value.Radius <= 0 || value.Width <= 0 {
			return nil, fmt.Errorf("stroked circle center, radius, and width must be finite and positive")
		}
		return circleVertices(transform.point(value.Center), value.Radius*transform.zoom, value.Width*transform.zoom, value.Color, viewportWidth, viewportHeight), nil
	case render.StrokeLine:
		value, ok := command.Payload.(render.LineDraw)
		if !ok {
			return nil, fmt.Errorf("line command has payload %T", command.Payload)
		}
		if !finite(value.Start.X) || !finite(value.Start.Y) || !finite(value.End.X) || !finite(value.End.Y) || !finite(value.Width) || value.Width <= 0 {
			return nil, fmt.Errorf("line endpoints and width must be finite and positive")
		}
		start := transform.point(value.Start)
		end := transform.point(value.End)
		dx, dy := end.X-start.X, end.Y-start.Y
		length := math.Hypot(dx, dy)
		if length == 0 {
			return circleVertices(start, value.Width/2, 0, value.Color, viewportWidth, viewportHeight), nil
		}
		half := value.Width * transform.zoom / 2
		normal := render.Vec2{X: -dy / length * half, Y: dx / length * half}
		vertices := toVertices([]render.Vec2{{X: start.X + normal.X, Y: start.Y + normal.Y}, {X: end.X + normal.X, Y: end.Y + normal.Y}, {X: end.X - normal.X, Y: end.Y - normal.Y}, {X: start.X + normal.X, Y: start.Y + normal.Y}, {X: end.X - normal.X, Y: end.Y - normal.Y}, {X: start.X - normal.X, Y: start.Y - normal.Y}}, value.Color)
		angle := math.Atan2(dy, dx)
		vertices = append(vertices, semicircleVertices(start, angle+math.Pi/2, angle+3*math.Pi/2, half, value.Color, viewportWidth, viewportHeight)...)
		vertices = append(vertices, semicircleVertices(end, angle-math.Pi/2, angle+math.Pi/2, half, value.Color, viewportWidth, viewportHeight)...)
		return vertices, nil
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
	segments := circleSegments(radius)
	color := tintValue(tint)
	vertices := make([]vertex, 0, segments*6)
	outerRadius := radius
	innerRadius := 0.0
	if width > 0 {
		outerRadius = radius + width/2
		innerRadius = math.Max(0, radius-width/2)
		segments = circleSegments(outerRadius)
		vertices = make([]vertex, 0, segments*6)
	}
	if width <= 0 || innerRadius == 0 {
		for index := 0; index < segments; index++ {
			start := circlePoint(center, outerRadius, index, segments)
			end := circlePoint(center, outerRadius, index+1, segments)
			vertices = append(vertices, vertexAt(center, 0, 0, color, viewportWidth, viewportHeight), vertexAt(start, 0, 0, color, viewportWidth, viewportHeight), vertexAt(end, 0, 0, color, viewportWidth, viewportHeight))
		}
		return vertices
	}
	for index := 0; index < segments; index++ {
		outerStart := circlePoint(center, outerRadius, index, segments)
		outerEnd := circlePoint(center, outerRadius, index+1, segments)
		innerStart := circlePoint(center, innerRadius, index, segments)
		innerEnd := circlePoint(center, innerRadius, index+1, segments)
		vertices = append(vertices, vertexAt(outerStart, 0, 0, color, viewportWidth, viewportHeight), vertexAt(outerEnd, 0, 0, color, viewportWidth, viewportHeight), vertexAt(innerEnd, 0, 0, color, viewportWidth, viewportHeight), vertexAt(outerStart, 0, 0, color, viewportWidth, viewportHeight), vertexAt(innerEnd, 0, 0, color, viewportWidth, viewportHeight), vertexAt(innerStart, 0, 0, color, viewportWidth, viewportHeight))
	}
	return vertices
}

func semicircleVertices(center render.Vec2, startAngle, endAngle, radius float64, tint render.Color, viewportWidth, viewportHeight int) []vertex {
	segments := max(8, circleSegments(radius)/2)
	color := tintValue(tint)
	vertices := make([]vertex, 0, segments*3)
	for index := 0; index < segments; index++ {
		start := circlePointAtAngle(center, radius, startAngle+(endAngle-startAngle)*float64(index)/float64(segments))
		end := circlePointAtAngle(center, radius, startAngle+(endAngle-startAngle)*float64(index+1)/float64(segments))
		vertices = append(vertices, vertexAt(center, 0, 0, color, viewportWidth, viewportHeight), vertexAt(start, 0, 0, color, viewportWidth, viewportHeight), vertexAt(end, 0, 0, color, viewportWidth, viewportHeight))
	}
	return vertices
}

func circleSegments(radius float64) int {
	if radius <= 0 {
		return 32
	}
	segments := int(math.Ceil(math.Pi / math.Acos(math.Max(-1, 1-.25/radius))))
	return min(256, max(32, segments))
}

func circlePoint(center render.Vec2, radius float64, index, segments int) render.Vec2 {
	angle := float64(index) / float64(segments) * 2 * math.Pi
	return circlePointAtAngle(center, radius, angle)
}

func circlePointAtAngle(center render.Vec2, radius, angle float64) render.Vec2 {
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

func encodeSpriteInstances(instances []spriteInstanceData) []byte {
	data := make([]byte, len(instances)*spriteInstanceStride)
	for index, instance := range instances {
		offset := index * spriteInstanceStride
		for _, values := range [][4]float32{instance.points01, instance.points23, instance.texcoords, instance.tint} {
			for component, value := range values {
				binary.LittleEndian.PutUint32(data[offset+component*4:], math.Float32bits(value))
			}
			offset += 16
		}
	}
	return data
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func finiteRect(value render.Rect) bool {
	return finite(value.X) && finite(value.Y) && finite(value.W) && finite(value.H)
}
