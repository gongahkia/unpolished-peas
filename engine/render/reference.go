package render

import (
	"fmt"
	"image"
	"image/color"
	"math"
	"sort"

	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

// ReferenceBackend is a deterministic CPU implementation of Backend for
// command and image regression tests. It is not a production renderer.
type ReferenceBackend struct {
	image Image
}

// NewReferenceBackend creates a transparent RGBA8 target with logical pixel
// dimensions width by height.
func NewReferenceBackend(width, height int) (*ReferenceBackend, error) {
	length, ok := imageByteLen(width, height)
	if !ok {
		return nil, fmt.Errorf("reference target dimensions must be positive and addressable")
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
func (b *ReferenceBackend) Render(frame Frame) error {
	if b == nil {
		return fmt.Errorf("reference backend must not be nil")
	}
	if !validImage(b.image) {
		return fmt.Errorf("reference backend target must be initialized")
	}
	if frame.Queue == nil {
		return fmt.Errorf("render frame queue must not be nil")
	}
	commands := frame.Queue.Commands()
	for _, command := range commands {
		if command.Kind != Clear {
			continue
		}
		value, ok := command.Payload.(Color)
		if !ok {
			return fmt.Errorf("clear command has payload %T", command.Payload)
		}
		b.Reset(value)
	}
	sort.SliceStable(commands, func(left, right int) bool {
		if commands[left].Kind == Clear {
			return true
		}
		if commands[right].Kind == Clear {
			return false
		}
		return commands[left].Layer < commands[right].Layer
	})
	for _, command := range commands {
		if command.Kind == Clear {
			continue
		}
		if err := b.draw(frame, command); err != nil {
			return err
		}
	}
	return nil
}

func (b *ReferenceBackend) draw(frame Frame, command Command) error {
	offset, err := commandOffset(frame.Camera, command.Space)
	if err != nil {
		return err
	}
	switch command.Kind {
	case SpriteCommand:
		value, ok := command.Payload.(Sprite)
		if !ok {
			return fmt.Errorf("sprite command has payload %T", command.Payload)
		}
		return b.drawSprite(frame.Textures, value, offset)
	case TileMapCommand:
		value, ok := command.Payload.(TileMap)
		if !ok {
			return fmt.Errorf("tile map command has payload %T", command.Payload)
		}
		return b.drawTileMap(frame.Textures, value, offset)
	case FillRect:
		value, ok := command.Payload.(RectDraw)
		if !ok {
			return fmt.Errorf("filled rectangle command has payload %T", command.Payload)
		}
		return b.fillRect(translateRect(value.Bounds, offset), value.Color)
	case StrokeRect:
		value, ok := command.Payload.(RectDraw)
		if !ok {
			return fmt.Errorf("stroked rectangle command has payload %T", command.Payload)
		}
		return b.strokeRect(translateRect(value.Bounds, offset), value.Width, value.Color)
	case FillCircle:
		value, ok := command.Payload.(CircleDraw)
		if !ok {
			return fmt.Errorf("filled circle command has payload %T", command.Payload)
		}
		return b.fillCircle(Vec2{X: value.Center.X + offset.X, Y: value.Center.Y + offset.Y}, value.Radius, value.Color)
	case StrokeLine:
		value, ok := command.Payload.(LineDraw)
		if !ok {
			return fmt.Errorf("line command has payload %T", command.Payload)
		}
		return b.strokeLine(
			Vec2{X: value.Start.X + offset.X, Y: value.Start.Y + offset.Y},
			Vec2{X: value.End.X + offset.X, Y: value.End.Y + offset.Y},
			value.Width,
			value.Color,
		)
	case Text:
		value, ok := command.Payload.(TextDraw)
		if !ok {
			return fmt.Errorf("text command has payload %T", command.Payload)
		}
		b.drawText(Vec2{X: value.Position.X + offset.X, Y: value.Position.Y + offset.Y}, value.Value, value.Color)
		return nil
	default:
		return fmt.Errorf("unsupported render command %d", command.Kind)
	}
}

func commandOffset(camera Camera, space Space) (Vec2, error) {
	switch space {
	case ScreenSpace:
		return Vec2{}, nil
	case WorldSpace:
		return Vec2{X: -camera.Position.X, Y: -camera.Position.Y}, nil
	default:
		return Vec2{}, fmt.Errorf("render command has invalid space %d", space)
	}
}

func (b *ReferenceBackend) drawSprite(store *TextureStore, sprite Sprite, offset Vec2) error {
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
	bounds := translateRect(sprite.Bounds, offset)
	for y := maxIntValue(0, int(math.Floor(bounds.Y))); y < minIntValue(b.image.Height, int(math.Ceil(bounds.Y+bounds.H))); y++ {
		for x := maxIntValue(0, int(math.Floor(bounds.X))); x < minIntValue(b.image.Width, int(math.Ceil(bounds.X+bounds.W))); x++ {
			centerX, centerY := float64(x)+.5, float64(y)+.5
			if centerX < bounds.X || centerX >= bounds.X+bounds.W || centerY < bounds.Y || centerY >= bounds.Y+bounds.H {
				continue
			}
			sourceX := sampleCoordinate(region.X+(centerX-bounds.X)*region.W/bounds.W, region.X, region.X+region.W)
			sourceY := sampleCoordinate(region.Y+(centerY-bounds.Y)*region.H/bounds.H, region.Y, region.Y+region.H)
			pixel := sourceColor(source, sourceX, sourceY)
			b.blend(x, y, scaleColor(pixel, sprite.Tint))
		}
	}
	return nil
}

func (b *ReferenceBackend) drawTileMap(store *TextureStore, tiles TileMap, offset Vec2) error {
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
	for index, tile := range tiles.Tiles {
		if tile < 0 {
			continue
		}
		column, row := index%tiles.Columns, index/tiles.Columns
		sourceColumn, sourceRow := tile%sourceColumns, tile/sourceColumns
		sprite := Sprite{
			Texture: tiles.Texture,
			Source:  Rect{X: float64(sourceColumn) * tiles.TileSize.X, Y: float64(sourceRow) * tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
			Bounds:  Rect{X: tiles.Bounds.X + float64(column)*tiles.TileSize.X, Y: tiles.Bounds.Y + float64(row)*tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
			Tint:    tiles.Tint,
		}
		if err := b.drawSprite(store, sprite, offset); err != nil {
			return err
		}
	}
	return nil
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

func (b *ReferenceBackend) drawText(position Vec2, value string, tint Color) {
	if !finiteVec(position) {
		return
	}
	target := &image.NRGBA{Pix: b.image.Pixels, Stride: b.image.Width * 4, Rect: image.Rect(0, 0, b.image.Width, b.image.Height)}
	drawer := font.Drawer{
		Dst:  target,
		Src:  image.NewUniform(color.NRGBA{R: tint.R, G: tint.G, B: tint.B, A: tint.A}),
		Face: basicfont.Face7x13,
		Dot:  fixed.P(int(position.X), int(position.Y)),
	}
	drawer.DrawString(value)
}

func (b *ReferenceBackend) forPixels(bounds Rect, include func(Vec2) bool, tint Color) {
	for y := maxIntValue(0, int(math.Floor(bounds.Y))); y < minIntValue(b.image.Height, int(math.Ceil(bounds.Y+bounds.H))); y++ {
		for x := maxIntValue(0, int(math.Floor(bounds.X))); x < minIntValue(b.image.Width, int(math.Ceil(bounds.X+bounds.W))); x++ {
			if include(Vec2{X: float64(x) + .5, Y: float64(y) + .5}) {
				b.blend(x, y, tint)
			}
		}
	}
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

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func finiteVec(value Vec2) bool { return finite(value.X) && finite(value.Y) }

func finiteRect(value Rect) bool {
	return finite(value.X) && finite(value.Y) && finite(value.W) && finite(value.H)
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

var _ Backend = (*ReferenceBackend)(nil)
