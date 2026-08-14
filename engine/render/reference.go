package render

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"math"
	"time"

	"github.com/gongahkia/72/engine/diagnostics"
	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

// ReferenceBackend is a deterministic CPU implementation of Backend for
// command and image regression tests. It is not a production renderer.
type ReferenceBackend struct {
	image Image
	clip  *Rect
}

// NewReferenceBackend creates a transparent RGBA8 target with logical pixel
// dimensions width by height.
func NewReferenceBackend(width, height int) (*ReferenceBackend, error) {
	length, ok := imageByteLen(width, height)
	if !ok {
		return nil, rendererFailure("initialize reference target", fmt.Errorf("reference target dimensions must be positive and addressable"), diagnostics.CorrectConfiguration, true)
	}
	return &ReferenceBackend{image: Image{Width: width, Height: height, Pixels: make([]byte, length)}}, nil
}

// Reset replaces every target pixel with color.
func (b *ReferenceBackend) Reset(color Color) {
	if b == nil {
		return
	}
	for offset := 0; offset < len(b.image.Pixels); offset += 4 {
		b.image.Pixels[offset] = color.R
		b.image.Pixels[offset+1] = color.G
		b.image.Pixels[offset+2] = color.B
		b.image.Pixels[offset+3] = color.A
	}
}

// Snapshot returns a copy of the current RGBA8 target.
func (b *ReferenceBackend) Snapshot() Image {
	if b == nil {
		return Image{}
	}
	return Image{Width: b.image.Width, Height: b.image.Height, Pixels: append([]byte(nil), b.image.Pixels...)}
}

// Render applies a full high-level command frame. Clear commands are processed
// before every other command, and non-clear commands retain stable layer order.
func (b *ReferenceBackend) Render(frame Frame) (err error) {
	traceDone := frame.Trace.Span("renderer.reference.frame")
	defer traceDone()
	if b == nil {
		return rendererFailure("render reference frame", fmt.Errorf("reference backend must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	if !validImage(b.image) {
		return rendererFailure("render reference frame", fmt.Errorf("reference backend target must be initialized"), diagnostics.CorrectConfiguration, true)
	}
	if frame.Queue == nil {
		return rendererFailure("render reference frame", fmt.Errorf("render frame queue must not be nil"), diagnostics.CorrectInput, false)
	}
	metrics := CollectFrameMetrics(frame, Rect{W: float64(b.image.Width), H: float64(b.image.Height)})
	started := time.Now()
	defer func() {
		metrics.Duration = time.Since(started)
		metrics.RecordInto(frame.Diagnostics)
	}()
	commands := orderedCommands(frame.Queue.Commands())
	for _, command := range commands {
		if command.Kind != Clear {
			continue
		}
		value, ok := command.Payload.(Color)
		if !ok {
			return rendererFailure("render reference frame", fmt.Errorf("clear command has payload %T", command.Payload), diagnostics.CorrectInput, false)
		}
		b.Reset(value)
	}
	for _, command := range commands {
		if command.Kind == Clear {
			continue
		}
		if err := b.draw(frame, command); err != nil {
			return rendererFailure("render reference frame", err, diagnostics.CorrectInput, false)
		}
	}
	return nil
}

// RenderTo applies frame to target and updates its portable TextureStore image.
// The reference backend's main target remains unchanged.
func (b *ReferenceBackend) RenderTo(frame Frame, target RenderTarget) error {
	if b == nil {
		return rendererFailure("render reference target", fmt.Errorf("reference backend must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	if frame.Textures == nil {
		return rendererFailure("render reference target", fmt.Errorf("render target requires an engine texture store"), diagnostics.CorrectInput, false)
	}
	image, ok := frame.Textures.TargetImage(target)
	if !ok {
		return rendererFailure("render reference target", fmt.Errorf("render target texture %d is not registered", target.Texture.ID), diagnostics.CorrectInput, false)
	}
	main := b.image
	b.image = image
	err := b.Render(frame)
	rendered := b.image
	b.image = main
	if err != nil {
		return err
	}
	if err := frame.Textures.replaceTarget(target, rendered); err != nil {
		return rendererFailure("render reference target", err, diagnostics.CorrectInput, false)
	}
	return nil
}

func (b *ReferenceBackend) draw(frame Frame, command Command) error {
	previousClip := b.clip
	if clip, ok := command.Clip(); ok {
		b.clip = &clip
	} else {
		b.clip = nil
	}
	defer func() { b.clip = previousClip }()
	transform, err := newCameraTransform(frame.Camera, command.Space)
	if err != nil {
		return err
	}
	switch command.Kind {
	case SpriteCommand:
		value, ok := command.Payload.(Sprite)
		if !ok {
			return fmt.Errorf("sprite command has payload %T", command.Payload)
		}
		return b.drawSprite(frame.Textures, value, transform)
	case TileMapCommand:
		value, ok := command.Payload.(TileMap)
		if !ok {
			return fmt.Errorf("tile map command has payload %T", command.Payload)
		}
		return b.drawTileMap(frame.Textures, value, transform)
	case FillRect:
		value, ok := command.Payload.(RectDraw)
		if !ok {
			return fmt.Errorf("filled rectangle command has payload %T", command.Payload)
		}
		return b.fillRect(transform.rect(value.Bounds), value.Color)
	case StrokeRect:
		value, ok := command.Payload.(RectDraw)
		if !ok {
			return fmt.Errorf("stroked rectangle command has payload %T", command.Payload)
		}
		return b.strokeRect(transform.rect(value.Bounds), value.Width*transform.zoom, value.Color)
	case FillCircle:
		value, ok := command.Payload.(CircleDraw)
		if !ok {
			return fmt.Errorf("filled circle command has payload %T", command.Payload)
		}
		return b.fillCircle(transform.point(value.Center), value.Radius*transform.zoom, value.Color)
	case StrokeCircle:
		value, ok := command.Payload.(CircleDraw)
		if !ok {
			return fmt.Errorf("stroked circle command has payload %T", command.Payload)
		}
		return b.strokeCircle(transform.point(value.Center), value.Radius*transform.zoom, value.Width*transform.zoom, value.Color)
	case StrokeLine:
		value, ok := command.Payload.(LineDraw)
		if !ok {
			return fmt.Errorf("line command has payload %T", command.Payload)
		}
		return b.strokeLine(transform.point(value.Start), transform.point(value.End), value.Width*transform.zoom, value.Color)
	case Text:
		value, ok := command.Payload.(TextDraw)
		if !ok {
			return fmt.Errorf("text command has payload %T", command.Payload)
		}
		return b.drawText(value.Position, value.Value, value.Color, value.Atlas, transform)
	default:
		return fmt.Errorf("unsupported render command %d", command.Kind)
	}
}

func (b *ReferenceBackend) drawSprite(store *TextureStore, sprite Sprite, view cameraTransform) error {
	if !finiteRect(sprite.Bounds) || sprite.Bounds.W <= 0 || sprite.Bounds.H <= 0 {
		return fmt.Errorf("sprite bounds must be finite and positive")
	}
	if store == nil {
		return fmt.Errorf("texture %d is not available without an engine texture store", sprite.Texture.ID)
	}
	source, ok := store.Image(sprite.Texture)
	if !ok {
		return fmt.Errorf("texture %d is not registered", sprite.Texture.ID)
	}
	region := sprite.Source
	if region.W == 0 && region.H == 0 {
		region.W = float64(source.Width)
		region.H = float64(source.Height)
	}
	if !finiteRect(region) || region.W <= 0 || region.H <= 0 {
		return fmt.Errorf("sprite source must be finite and positive")
	}
	if region.X < 0 || region.Y < 0 || region.X+region.W > float64(source.Width) || region.Y+region.H > float64(source.Height) {
		return fmt.Errorf("sprite source is outside texture %d", sprite.Texture.ID)
	}
	bounds := sprite.Bounds
	transform := normalizeSpriteTransform(sprite.Transform)
	origin := Vec2{X: bounds.X + sprite.Transform.Origin.X*bounds.W, Y: bounds.Y + sprite.Transform.Origin.Y*bounds.H}
	transformed := view.rect(transformedSpriteBounds(bounds, origin, transform))
	for y := maxIntValue(0, int(math.Floor(transformed.Y))); y < minIntValue(b.image.Height, int(math.Ceil(transformed.Y+transformed.H))); y++ {
		for x := maxIntValue(0, int(math.Floor(transformed.X))); x < minIntValue(b.image.Width, int(math.Ceil(transformed.X+transformed.W))); x++ {
			if !b.visible(x, y) {
				continue
			}
			local := inverseSpritePoint(view.inversePoint(Vec2{X: float64(x) + .5, Y: float64(y) + .5}), origin, transform)
			if local.X < bounds.X || local.X >= bounds.X+bounds.W || local.Y < bounds.Y || local.Y >= bounds.Y+bounds.H {
				continue
			}
			sourceX := sampleCoordinate(region.X+(local.X-bounds.X)*region.W/bounds.W, region.X, region.X+region.W)
			sourceY := sampleCoordinate(region.Y+(local.Y-bounds.Y)*region.H/bounds.H, region.Y, region.Y+region.H)
			pixel := sourceColor(source, sourceX, sourceY)
			b.blend(x, y, scaleColor(pixel, sprite.Tint))
		}
	}
	return nil
}

type spriteTransformValue struct{ scaleX, scaleY, rotation float64 }

func normalizeSpriteTransform(transform SpriteTransform) spriteTransformValue {
	value := spriteTransformValue{scaleX: transform.ScaleX, scaleY: transform.ScaleY, rotation: transform.Rotation}
	if value.scaleX == 0 {
		value.scaleX = 1
	}
	if value.scaleY == 0 {
		value.scaleY = 1
	}
	return value
}

func inverseSpritePoint(point, origin Vec2, transform spriteTransformValue) Vec2 {
	x, y := point.X-origin.X, point.Y-origin.Y
	cosine, sine := math.Cos(transform.rotation), math.Sin(transform.rotation)
	return Vec2{X: origin.X + (cosine*x+sine*y)/transform.scaleX, Y: origin.Y + (-sine*x+cosine*y)/transform.scaleY}
}

func transformedSpriteBounds(bounds Rect, origin Vec2, transform spriteTransformValue) Rect {
	points := []Vec2{{X: bounds.X, Y: bounds.Y}, {X: bounds.X + bounds.W, Y: bounds.Y}, {X: bounds.X, Y: bounds.Y + bounds.H}, {X: bounds.X + bounds.W, Y: bounds.Y + bounds.H}}
	minimum, maximum := transformSpritePoint(points[0], origin, transform), transformSpritePoint(points[0], origin, transform)
	for _, point := range points[1:] {
		point = transformSpritePoint(point, origin, transform)
		minimum.X, minimum.Y = math.Min(minimum.X, point.X), math.Min(minimum.Y, point.Y)
		maximum.X, maximum.Y = math.Max(maximum.X, point.X), math.Max(maximum.Y, point.Y)
	}
	return Rect{X: minimum.X, Y: minimum.Y, W: maximum.X - minimum.X, H: maximum.Y - minimum.Y}
}

func transformSpritePoint(point, origin Vec2, transform spriteTransformValue) Vec2 {
	x, y := (point.X-origin.X)*transform.scaleX, (point.Y-origin.Y)*transform.scaleY
	cosine, sine := math.Cos(transform.rotation), math.Sin(transform.rotation)
	return Vec2{X: origin.X + cosine*x - sine*y, Y: origin.Y + sine*x + cosine*y}
}

func (b *ReferenceBackend) drawTileMap(store *TextureStore, tiles TileMap, transform cameraTransform) error {
	if !finiteRect(tiles.Bounds) || !finiteVec(tiles.Atlas) || !finiteVec(tiles.TileSize) {
		return fmt.Errorf("tile map coordinates must be finite")
	}
	if tiles.Columns <= 0 || tiles.TileSize.X <= 0 || tiles.TileSize.Y <= 0 || tiles.Atlas.X <= 0 || tiles.Atlas.Y <= 0 {
		return fmt.Errorf("tile map requires positive atlas, tile size, and columns")
	}
	sourceColumns := int(tiles.Atlas.X / tiles.TileSize.X)
	if sourceColumns <= 0 {
		return fmt.Errorf("tile map atlas is narrower than a tile")
	}
	visible := tiles.VisibleRange(b.tileViewport(transform))
	for row := visible.Row; row < visible.Row+visible.Rows; row++ {
		for column := visible.Column; column < visible.Column+visible.Columns; column++ {
			index := row*tiles.Columns + column
			if index >= len(tiles.Tiles) {
				continue
			}
			tile := tiles.Tiles[index]
			if tile < 0 {
				continue
			}
			sourceColumn, sourceRow := tile%sourceColumns, tile/sourceColumns
			sprite := Sprite{
				Texture: tiles.Texture,
				Source:  Rect{X: float64(sourceColumn) * tiles.TileSize.X, Y: float64(sourceRow) * tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Bounds:  Rect{X: tiles.Bounds.X + float64(column)*tiles.TileSize.X, Y: tiles.Bounds.Y + float64(row)*tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Tint:    tiles.Tint,
			}
			if err := b.drawSprite(store, sprite, transform); err != nil {
				return err
			}
		}
	}
	return nil
}

func (b *ReferenceBackend) tileViewport(transform cameraTransform) Rect {
	viewport := Rect{W: float64(b.image.Width), H: float64(b.image.Height)}
	if b.clip == nil {
		return transform.inverseRect(viewport)
	}
	return transform.inverseRect(intersectRects(viewport, *b.clip))
}

func (b *ReferenceBackend) fillRect(bounds Rect, tint Color) error {
	if !finiteRect(bounds) || bounds.W <= 0 || bounds.H <= 0 {
		return fmt.Errorf("rectangle bounds must be finite and positive")
	}
	b.forPixels(bounds, func(center Vec2) bool {
		return center.X >= bounds.X && center.X < bounds.X+bounds.W && center.Y >= bounds.Y && center.Y < bounds.Y+bounds.H
	}, tint)
	return nil
}

func (b *ReferenceBackend) strokeRect(bounds Rect, width float64, tint Color) error {
	if !finiteRect(bounds) || !finite(width) || bounds.W <= 0 || bounds.H <= 0 || width <= 0 {
		return fmt.Errorf("stroked rectangle bounds and width must be finite and positive")
	}
	inner := Rect{X: bounds.X + width, Y: bounds.Y + width, W: bounds.W - 2*width, H: bounds.H - 2*width}
	b.forPixels(bounds, func(center Vec2) bool {
		inside := center.X >= bounds.X && center.X < bounds.X+bounds.W && center.Y >= bounds.Y && center.Y < bounds.Y+bounds.H
		if !inside {
			return false
		}
		return inner.W <= 0 || inner.H <= 0 || center.X < inner.X || center.X >= inner.X+inner.W || center.Y < inner.Y || center.Y >= inner.Y+inner.H
	}, tint)
	return nil
}

func (b *ReferenceBackend) fillCircle(center Vec2, radius float64, tint Color) error {
	if !finiteVec(center) || !finite(radius) || radius <= 0 {
		return fmt.Errorf("circle center and radius must be finite and positive")
	}
	b.forPixels(Rect{X: center.X - radius, Y: center.Y - radius, W: 2 * radius, H: 2 * radius}, func(pixel Vec2) bool {
		dx, dy := pixel.X-center.X, pixel.Y-center.Y
		return dx*dx+dy*dy <= radius*radius
	}, tint)
	return nil
}

func (b *ReferenceBackend) strokeCircle(center Vec2, radius, width float64, tint Color) error {
	if !finiteVec(center) || !finite(radius) || !finite(width) || radius <= 0 || width <= 0 {
		return fmt.Errorf("stroked circle center, radius, and width must be finite and positive")
	}
	outerRadius := radius + width/2
	innerRadius := math.Max(0, radius-width/2)
	b.forPixels(Rect{X: center.X - outerRadius, Y: center.Y - outerRadius, W: 2 * outerRadius, H: 2 * outerRadius}, func(pixel Vec2) bool {
		dx, dy := pixel.X-center.X, pixel.Y-center.Y
		distanceSquared := dx*dx + dy*dy
		return distanceSquared <= outerRadius*outerRadius && distanceSquared >= innerRadius*innerRadius
	}, tint)
	return nil
}

func (b *ReferenceBackend) strokeLine(start, end Vec2, width float64, tint Color) error {
	if !finiteVec(start) || !finiteVec(end) || !finite(width) || width <= 0 {
		return fmt.Errorf("line endpoints and width must be finite and positive")
	}
	radius := width / 2
	bounds := Rect{
		X: minFloat(start.X, end.X) - radius,
		Y: minFloat(start.Y, end.Y) - radius,
		W: math.Abs(end.X-start.X) + width,
		H: math.Abs(end.Y-start.Y) + width,
	}
	b.forPixels(bounds, func(pixel Vec2) bool {
		return pointSegmentDistanceSquared(pixel, start, end) <= radius*radius
	}, tint)
	return nil
}

func (b *ReferenceBackend) drawText(position Vec2, value string, tint Color, atlas *GlyphAtlas, transform cameraTransform) error {
	if !finiteVec(position) {
		return fmt.Errorf("text position must be finite")
	}
	if atlas != nil {
		return b.drawAtlasText(position, value, tint, atlas, transform)
	}
	if transform.zoom != 1 {
		return b.drawScaledBasicText(position, value, tint, transform)
	}
	position = transform.point(position)
	target := &image.NRGBA{Pix: b.image.Pixels, Stride: b.image.Width * 4, Rect: image.Rect(0, 0, b.image.Width, b.image.Height)}
	var destination draw.Image = target
	if b.clip != nil {
		destination = clippedImage{NRGBA: target, clip: *b.clip}
	}
	drawer := font.Drawer{
		Dst:  destination,
		Src:  image.NewUniform(color.NRGBA{R: tint.R, G: tint.G, B: tint.B, A: tint.A}),
		Face: basicfont.Face7x13,
		Dot:  fixed.P(int(position.X), int(position.Y)),
	}
	drawer.DrawString(value)
	return nil
}

func (b *ReferenceBackend) drawAtlasText(position Vec2, value string, tint Color, atlas *GlyphAtlas, transform cameraTransform) error {
	pen := position.X
	for _, rune := range value {
		glyph, err := atlas.Glyph(rune)
		if err != nil {
			return fmt.Errorf("resolve glyph %q: %w", rune, err)
		}
		if glyph.Source.W > 0 && glyph.Source.H > 0 {
			page, _, ok := atlas.Page(glyph.Page)
			if !ok {
				return fmt.Errorf("glyph atlas page %d is unavailable", glyph.Page)
			}
			if err := b.drawImage(page, glyph.Source, transform.rect(Rect{X: pen + glyph.Offset.X, Y: position.Y + glyph.Offset.Y, W: glyph.Source.W, H: glyph.Source.H}), tint); err != nil {
				return err
			}
		}
		pen += glyph.Advance
	}
	return nil
}

func (b *ReferenceBackend) drawScaledBasicText(position Vec2, value string, tint Color, transform cameraTransform) error {
	pen := position.X
	for _, runeValue := range value {
		glyph := image.NewNRGBA(image.Rect(0, 0, 8, 13))
		drawer := font.Drawer{Dst: glyph, Src: image.NewUniform(color.NRGBA{R: tint.R, G: tint.G, B: tint.B, A: tint.A}), Face: basicfont.Face7x13, Dot: fixed.P(0, 13)}
		drawer.DrawString(string(runeValue))
		source, err := NewImage(8, 13, glyph.Pix)
		if err != nil {
			return err
		}
		if err := b.drawImage(source, Rect{W: 8, H: 13}, transform.rect(Rect{X: pen, Y: position.Y - 13, W: 8, H: 13}), Color{R: 255, G: 255, B: 255, A: 255}); err != nil {
			return err
		}
		advance, ok := basicfont.Face7x13.GlyphAdvance(runeValue)
		if !ok {
			advance = fixed.I(7)
		}
		pen += float64(advance) / 64
	}
	return nil
}

func (b *ReferenceBackend) drawImage(source Image, region, bounds Rect, tint Color) error {
	if !finiteRect(region) || region.W <= 0 || region.H <= 0 || region.X < 0 || region.Y < 0 || region.X+region.W > float64(source.Width) || region.Y+region.H > float64(source.Height) {
		return fmt.Errorf("image source is outside portable image")
	}
	if !finiteRect(bounds) || bounds.W <= 0 || bounds.H <= 0 {
		return fmt.Errorf("image bounds must be finite and positive")
	}
	for y := maxIntValue(0, int(math.Floor(bounds.Y))); y < minIntValue(b.image.Height, int(math.Ceil(bounds.Y+bounds.H))); y++ {
		for x := maxIntValue(0, int(math.Floor(bounds.X))); x < minIntValue(b.image.Width, int(math.Ceil(bounds.X+bounds.W))); x++ {
			if !b.visible(x, y) {
				continue
			}
			centerX, centerY := float64(x)+.5, float64(y)+.5
			if centerX < bounds.X || centerX >= bounds.X+bounds.W || centerY < bounds.Y || centerY >= bounds.Y+bounds.H {
				continue
			}
			sourceX := sampleCoordinate(region.X+(centerX-bounds.X)*region.W/bounds.W, region.X, region.X+region.W)
			sourceY := sampleCoordinate(region.Y+(centerY-bounds.Y)*region.H/bounds.H, region.Y, region.Y+region.H)
			b.blend(x, y, scaleColor(sourceColor(source, sourceX, sourceY), tint))
		}
	}
	return nil
}

func (b *ReferenceBackend) forPixels(bounds Rect, include func(Vec2) bool, tint Color) {
	for y := maxIntValue(0, int(math.Floor(bounds.Y))); y < minIntValue(b.image.Height, int(math.Ceil(bounds.Y+bounds.H))); y++ {
		for x := maxIntValue(0, int(math.Floor(bounds.X))); x < minIntValue(b.image.Width, int(math.Ceil(bounds.X+bounds.W))); x++ {
			if b.visible(x, y) && include(Vec2{X: float64(x) + .5, Y: float64(y) + .5}) {
				b.blend(x, y, tint)
			}
		}
	}
}

func (b *ReferenceBackend) visible(x, y int) bool {
	if b.clip == nil {
		return true
	}
	center := Vec2{X: float64(x) + .5, Y: float64(y) + .5}
	return center.X >= b.clip.X && center.X < b.clip.X+b.clip.W && center.Y >= b.clip.Y && center.Y < b.clip.Y+b.clip.H
}

type clippedImage struct {
	*image.NRGBA
	clip Rect
}

func (i clippedImage) Set(x, y int, color color.Color) {
	if i.visible(x, y) {
		i.NRGBA.Set(x, y, color)
	}
}

func (i clippedImage) SetRGBA64(x, y int, color color.RGBA64) {
	if i.visible(x, y) {
		i.NRGBA.SetRGBA64(x, y, color)
	}
}

func (i clippedImage) visible(x, y int) bool {
	center := Vec2{X: float64(x) + .5, Y: float64(y) + .5}
	return center.X >= i.clip.X && center.X < i.clip.X+i.clip.W && center.Y >= i.clip.Y && center.Y < i.clip.Y+i.clip.H
}

func (b *ReferenceBackend) blend(x, y int, source Color) {
	offset := (y*b.image.Width + x) * 4
	destination := Color{R: b.image.Pixels[offset], G: b.image.Pixels[offset+1], B: b.image.Pixels[offset+2], A: b.image.Pixels[offset+3]}
	value := over(destination, source)
	b.image.Pixels[offset] = value.R
	b.image.Pixels[offset+1] = value.G
	b.image.Pixels[offset+2] = value.B
	b.image.Pixels[offset+3] = value.A
}

// ImageTolerance permits limited per-channel and per-pixel differences when a
// hardware integration test is intentionally compared with a reference image.
type ImageTolerance struct {
	PerChannel      uint8
	DifferentPixels int
}

// ImageComparison reports whether two images fit an ImageTolerance.
type ImageComparison struct {
	WithinTolerance      bool
	DifferentPixels      int
	MaxChannelDifference uint8
	FirstDifferenceX     int
	FirstDifferenceY     int
}

// CompareImages compares two portable RGBA8 images without mutating either.
func CompareImages(want, got Image, tolerance ImageTolerance) (ImageComparison, error) {
	if tolerance.DifferentPixels < 0 {
		return ImageComparison{}, fmt.Errorf("different-pixel tolerance must not be negative")
	}
	if !validImage(want) || !validImage(got) {
		return ImageComparison{}, fmt.Errorf("images must contain valid RGBA8 data")
	}
	if want.Width != got.Width || want.Height != got.Height {
		return ImageComparison{}, fmt.Errorf("image dimensions differ: want %dx%d, got %dx%d", want.Width, want.Height, got.Width, got.Height)
	}
	comparison := ImageComparison{WithinTolerance: true, FirstDifferenceX: -1, FirstDifferenceY: -1}
	for offset := 0; offset < len(want.Pixels); offset += 4 {
		pixelDifference := false
		for channel := 0; channel < 4; channel++ {
			difference := channelDifference(want.Pixels[offset+channel], got.Pixels[offset+channel])
			if difference > comparison.MaxChannelDifference {
				comparison.MaxChannelDifference = difference
			}
			if difference > tolerance.PerChannel {
				pixelDifference = true
			}
		}
		if !pixelDifference {
			continue
		}
		comparison.DifferentPixels++
		if comparison.FirstDifferenceX < 0 {
			pixel := offset / 4
			comparison.FirstDifferenceX = pixel % want.Width
			comparison.FirstDifferenceY = pixel / want.Width
		}
	}
	comparison.WithinTolerance = comparison.DifferentPixels <= tolerance.DifferentPixels
	return comparison, nil
}

func sourceColor(source Image, x, y int) Color {
	offset := (y*source.Width + x) * 4
	return Color{R: source.Pixels[offset], G: source.Pixels[offset+1], B: source.Pixels[offset+2], A: source.Pixels[offset+3]}
}

func sampleCoordinate(value, minimum, maximum float64) int {
	coordinate := int(math.Floor(value))
	return minIntValue(maxIntValue(coordinate, int(math.Floor(minimum))), int(math.Ceil(maximum))-1)
}

func scaleColor(source, tint Color) Color {
	return Color{
		R: uint8((uint16(source.R)*uint16(tint.R) + 127) / 255),
		G: uint8((uint16(source.G)*uint16(tint.G) + 127) / 255),
		B: uint8((uint16(source.B)*uint16(tint.B) + 127) / 255),
		A: uint8((uint16(source.A)*uint16(tint.A) + 127) / 255),
	}
}

func over(destination, source Color) Color {
	sourceAlpha, destinationAlpha := uint64(source.A), uint64(destination.A)
	alpha := sourceAlpha + (destinationAlpha*(255-sourceAlpha)+127)/255
	if alpha == 0 {
		return Color{}
	}
	channel := func(source, destination uint8) uint8 {
		premultiplied := uint64(source)*sourceAlpha + (uint64(destination)*destinationAlpha*(255-sourceAlpha)+127)/255
		return uint8((premultiplied + alpha/2) / alpha)
	}
	return Color{R: channel(source.R, destination.R), G: channel(source.G, destination.G), B: channel(source.B, destination.B), A: uint8(alpha)}
}

func pointSegmentDistanceSquared(point, start, end Vec2) float64 {
	dx, dy := end.X-start.X, end.Y-start.Y
	lengthSquared := dx*dx + dy*dy
	if lengthSquared == 0 {
		dx, dy := point.X-start.X, point.Y-start.Y
		return dx*dx + dy*dy
	}
	projection := ((point.X-start.X)*dx + (point.Y-start.Y)*dy) / lengthSquared
	projection = math.Max(0, math.Min(1, projection))
	dx, dy = point.X-(start.X+projection*dx), point.Y-(start.Y+projection*dy)
	return dx*dx + dy*dy
}

func translateRect(value Rect, offset Vec2) Rect {
	value.X += offset.X
	value.Y += offset.Y
	return value
}

func validImage(value Image) bool {
	length, ok := imageByteLen(value.Width, value.Height)
	return ok && len(value.Pixels) == length
}

func channelDifference(left, right uint8) uint8 {
	if left > right {
		return left - right
	}
	return right - left
}

func minFloat(left, right float64) float64 { return math.Min(left, right) }

func minIntValue(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func maxIntValue(left, right int) int {
	if left > right {
		return left
	}
	return right
}

func rendererFailure(operation string, cause error, recovery diagnostics.Recovery, terminal bool) error {
	return diagnostics.NewFailure(diagnostics.RendererSubsystem, operation, cause, recovery, terminal)
}

var _ Backend = (*ReferenceBackend)(nil)
var _ TargetBackend = (*ReferenceBackend)(nil)
