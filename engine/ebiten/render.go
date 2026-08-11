package ebiten

import (
	"fmt"
	"image"
	"image/color"
	"math"
	"sort"
	"time"

	"github.com/gongahkia/72/engine/render"
	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/text"
	"github.com/hajimehoshi/ebiten/v2/vector"
	"golang.org/x/image/font/basicfont"
)

// RenderBackend adapts engine/render's high-level 2D command contract to an
// Ebitengine render target. It exists only during 72's renderer transition;
// applications still depend only on engine/render types.
type RenderBackend struct {
	target         *ebiten.Image
	textures       map[uint64]*ebiten.Image
	renderTargets  map[uint64]*ebiten.Image
	atlasTextures  map[atlasPageKey]atlasPageTexture
	textureUploads uint64
}

type atlasPageKey struct {
	atlas *render.GlyphAtlas
	page  int
}
type atlasPageTexture struct {
	image    *ebiten.Image
	revision uint64
}

// NewRenderBackend creates a temporary renderer for target.
func NewRenderBackend(target *ebiten.Image) *RenderBackend {
	return &RenderBackend{target: target, textures: make(map[uint64]*ebiten.Image), renderTargets: make(map[uint64]*ebiten.Image), atlasTextures: make(map[atlasPageKey]atlasPageTexture)}
}

// SetTarget updates the Ebitengine target used for subsequent Render calls.
func (b *RenderBackend) SetTarget(target *ebiten.Image) { b.target = target }

// Render submits a high-level 2D frame to the configured Ebitengine target.
func (b *RenderBackend) Render(frame render.Frame) (err error) {
	if b.target == nil {
		return fmt.Errorf("Ebitengine render target must not be nil")
	}
	if frame.Queue == nil {
		return fmt.Errorf("render frame queue must not be nil")
	}
	metrics := render.CollectFrameMetrics(frame, render.Rect{W: float64(b.target.Bounds().Dx()), H: float64(b.target.Bounds().Dy())})
	uploads := b.textureUploads
	started := time.Now()
	defer func() {
		metrics.Duration = time.Since(started)
		metrics.TextureUploads = b.textureUploads - uploads
		metrics.NativeTextureEntries, metrics.NativeTextureBytes = b.cacheStats()
		metrics.RecordInto(frame.Diagnostics)
	}()
	commands := frame.Queue.Commands()
	for _, command := range commands {
		if command.Kind != render.Clear {
			continue
		}
		value, ok := command.Payload.(render.Color)
		if !ok {
			return fmt.Errorf("clear command has payload %T", command.Payload)
		}
		b.target.Fill(renderColor(value))
	}
	sort.SliceStable(commands, func(left, right int) bool {
		if commands[left].Kind == render.Clear {
			return true
		}
		if commands[right].Kind == render.Clear {
			return false
		}
		return commands[left].Layer < commands[right].Layer
	})
	for _, command := range commands {
		if command.Kind == render.Clear {
			continue
		}
		if err := b.draw(frame, command); err != nil {
			return err
		}
	}
	return nil
}

// RenderTo submits frame into target. The target remains available as a sprite
// source through the same RenderBackend after this call returns.
func (b *RenderBackend) RenderTo(frame render.Frame, target render.RenderTarget) error {
	destination, err := b.renderTarget(frame.Textures, target)
	if err != nil {
		return err
	}
	main := b.target
	b.target = destination
	err = b.Render(frame)
	b.target = main
	return err
}

func (b *RenderBackend) draw(frame render.Frame, command render.Command) error {
	if clip, clipped := command.Clip(); clipped {
		target, ok := b.clippedTarget(clip)
		if !ok {
			return nil
		}
		original := b.target
		b.target = target
		defer func() { b.target = original }()
	}
	translate := render.Vec2{}
	if command.Space == render.WorldSpace {
		translate = render.Vec2{X: -frame.Camera.Position.X, Y: -frame.Camera.Position.Y}
	}
	switch command.Kind {
	case render.SpriteCommand:
		value, ok := command.Payload.(render.Sprite)
		if !ok {
			return fmt.Errorf("sprite command has payload %T", command.Payload)
		}
		return b.drawSprite(frame.Textures, value, translate)
	case render.TileMapCommand:
		value, ok := command.Payload.(render.TileMap)
		if !ok {
			return fmt.Errorf("tile map command has payload %T", command.Payload)
		}
		return b.drawTileMap(frame.Textures, value, translate)
	case render.FillRect:
		value, ok := command.Payload.(render.RectDraw)
		if !ok {
			return fmt.Errorf("filled rectangle command has payload %T", command.Payload)
		}
		bounds := translateRect(value.Bounds, translate)
		vector.DrawFilledRect(b.target, float32(bounds.X), float32(bounds.Y), float32(bounds.W), float32(bounds.H), renderColor(value.Color), false)
	case render.StrokeRect:
		value, ok := command.Payload.(render.RectDraw)
		if !ok {
			return fmt.Errorf("stroked rectangle command has payload %T", command.Payload)
		}
		bounds := translateRect(value.Bounds, translate)
		vector.StrokeRect(b.target, float32(bounds.X), float32(bounds.Y), float32(bounds.W), float32(bounds.H), float32(value.Width), renderColor(value.Color), false)
	case render.FillCircle:
		value, ok := command.Payload.(render.CircleDraw)
		if !ok {
			return fmt.Errorf("filled circle command has payload %T", command.Payload)
		}
		vector.DrawFilledCircle(b.target, float32(value.Center.X+translate.X), float32(value.Center.Y+translate.Y), float32(value.Radius), renderColor(value.Color), true)
	case render.StrokeCircle:
		value, ok := command.Payload.(render.CircleDraw)
		if !ok {
			return fmt.Errorf("stroked circle command has payload %T", command.Payload)
		}
		vector.StrokeCircle(b.target, float32(value.Center.X+translate.X), float32(value.Center.Y+translate.Y), float32(value.Radius), float32(value.Width), renderColor(value.Color), true)
	case render.StrokeLine:
		value, ok := command.Payload.(render.LineDraw)
		if !ok {
			return fmt.Errorf("line command has payload %T", command.Payload)
		}
		vector.StrokeLine(b.target, float32(value.Start.X+translate.X), float32(value.Start.Y+translate.Y), float32(value.End.X+translate.X), float32(value.End.Y+translate.Y), float32(value.Width), renderColor(value.Color), true)
	case render.Text:
		value, ok := command.Payload.(render.TextDraw)
		if !ok {
			return fmt.Errorf("text command has payload %T", command.Payload)
		}
		if err := b.drawText(value, translate); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unsupported render command %d", command.Kind)
	}
	return nil
}

func (b *RenderBackend) clippedTarget(clip render.Rect) (*ebiten.Image, bool) {
	bounds := b.target.Bounds()
	region := image.Rect(
		clipPixelEdge(clip.X-.5, bounds.Min.X, bounds.Max.X),
		clipPixelEdge(clip.Y-.5, bounds.Min.Y, bounds.Max.Y),
		clipPixelEdge(clip.X+clip.W-.5, bounds.Min.X, bounds.Max.X),
		clipPixelEdge(clip.Y+clip.H-.5, bounds.Min.Y, bounds.Max.Y),
	)
	if region.Empty() {
		return nil, false
	}
	target, ok := b.target.SubImage(region).(*ebiten.Image)
	return target, ok && target != nil
}

func clipPixelEdge(value float64, minimum, maximum int) int {
	if value <= float64(minimum) {
		return minimum
	}
	if value >= float64(maximum) {
		return maximum
	}
	return int(math.Ceil(value))
}

func (b *RenderBackend) drawText(value render.TextDraw, translate render.Vec2) error {
	if value.Atlas == nil {
		text.Draw(b.target, value.Value, basicfont.Face7x13, int(value.Position.X+translate.X), int(value.Position.Y+translate.Y), renderColor(value.Color))
		return nil
	}
	pen := value.Position.X + translate.X
	for _, rune := range value.Value {
		glyph, err := value.Atlas.Glyph(rune)
		if err != nil {
			return fmt.Errorf("resolve glyph %q: %w", rune, err)
		}
		if glyph.Source.W > 0 && glyph.Source.H > 0 {
			page, err := b.atlasPage(value.Atlas, glyph.Page)
			if err != nil {
				return err
			}
			region := page.SubImage(image.Rect(int(glyph.Source.X), int(glyph.Source.Y), int(glyph.Source.X+glyph.Source.W), int(glyph.Source.Y+glyph.Source.H))).(*ebiten.Image)
			op := &ebiten.DrawImageOptions{}
			op.Filter = ebiten.FilterNearest
			op.GeoM.Translate(pen+glyph.Offset.X, value.Position.Y+translate.Y+glyph.Offset.Y)
			op.ColorScale.Scale(float32(value.Color.R)/255, float32(value.Color.G)/255, float32(value.Color.B)/255, float32(value.Color.A)/255)
			b.target.DrawImage(region, op)
		}
		pen += glyph.Advance
	}
	return nil
}

func (b *RenderBackend) atlasPage(atlas *render.GlyphAtlas, index int) (*ebiten.Image, error) {
	page, revision, ok := atlas.Page(index)
	if !ok {
		return nil, fmt.Errorf("glyph atlas page %d is unavailable", index)
	}
	key := atlasPageKey{atlas: atlas, page: index}
	if cached, ok := b.atlasTextures[key]; ok && cached.revision == revision {
		return cached.image, nil
	}
	decoded := image.NewNRGBA(image.Rect(0, 0, page.Width, page.Height))
	copy(decoded.Pix, page.Pixels)
	texture := ebiten.NewImageFromImage(decoded)
	b.atlasTextures[key] = atlasPageTexture{image: texture, revision: revision}
	b.textureUploads++
	return texture, nil
}

func (b *RenderBackend) drawSprite(store *render.TextureStore, sprite render.Sprite, translate render.Vec2) error {
	texture, err := b.texture(store, sprite.Texture)
	if err != nil {
		return err
	}
	source := sprite.Source
	if source.W == 0 && source.H == 0 {
		bounds := texture.Bounds()
		source = render.Rect{W: float64(bounds.Dx()), H: float64(bounds.Dy())}
	}
	if source.W <= 0 || source.H <= 0 {
		return fmt.Errorf("sprite source must be positive")
	}
	if source.X < 0 || source.Y < 0 || source.X+source.W > float64(texture.Bounds().Dx()) || source.Y+source.H > float64(texture.Bounds().Dy()) {
		return fmt.Errorf("sprite source is outside texture %d", sprite.Texture.ID)
	}
	image := texture.SubImage(image.Rect(int(source.X), int(source.Y), int(source.X+source.W), int(source.Y+source.H))).(*ebiten.Image)
	op := &ebiten.DrawImageOptions{}
	op.Filter = ebiten.FilterNearest
	transform := spriteTransform(sprite.Transform)
	origin := render.Vec2{X: sprite.Transform.Origin.X * sprite.Bounds.W, Y: sprite.Transform.Origin.Y * sprite.Bounds.H}
	op.GeoM.Scale(sprite.Bounds.W/source.W, sprite.Bounds.H/source.H)
	op.GeoM.Translate(-origin.X, -origin.Y)
	op.GeoM.Scale(transform.scaleX, transform.scaleY)
	op.GeoM.Rotate(transform.rotation)
	op.GeoM.Translate(sprite.Bounds.X+origin.X+translate.X, sprite.Bounds.Y+origin.Y+translate.Y)
	op.ColorScale.Scale(float32(sprite.Tint.R)/255, float32(sprite.Tint.G)/255, float32(sprite.Tint.B)/255, float32(sprite.Tint.A)/255)
	b.target.DrawImage(image, op)
	return nil
}

type normalizedSpriteTransform struct{ scaleX, scaleY, rotation float64 }

func spriteTransform(transform render.SpriteTransform) normalizedSpriteTransform {
	value := normalizedSpriteTransform{scaleX: transform.ScaleX, scaleY: transform.ScaleY, rotation: transform.Rotation}
	if value.scaleX == 0 {
		value.scaleX = 1
	}
	if value.scaleY == 0 {
		value.scaleY = 1
	}
	return value
}

func (b *RenderBackend) drawTileMap(store *render.TextureStore, tiles render.TileMap, translate render.Vec2) error {
	bounds := b.target.Bounds()
	visible := tiles.VisibleRange(render.Rect{X: float64(bounds.Min.X) - translate.X, Y: float64(bounds.Min.Y) - translate.Y, W: float64(bounds.Dx()), H: float64(bounds.Dy())})
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
			sourceColumns := int(tiles.Atlas.X / tiles.TileSize.X)
			if sourceColumns <= 0 {
				return fmt.Errorf("tile map atlas is narrower than a tile")
			}
			sourceColumn, sourceRow := tile%sourceColumns, tile/sourceColumns
			sprite := render.Sprite{
				Texture: tiles.Texture,
				Source:  render.Rect{X: float64(sourceColumn) * tiles.TileSize.X, Y: float64(sourceRow) * tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Bounds:  render.Rect{X: tiles.Bounds.X + float64(column)*tiles.TileSize.X, Y: tiles.Bounds.Y + float64(row)*tiles.TileSize.Y, W: tiles.TileSize.X, H: tiles.TileSize.Y},
				Tint:    tiles.Tint,
			}
			if err := b.drawSprite(store, sprite, translate); err != nil {
				return err
			}
		}
	}
	return nil
}

func (b *RenderBackend) texture(store *render.TextureStore, handle render.Texture) (*ebiten.Image, error) {
	if target := b.renderTargets[handle.ID]; target != nil {
		return target, nil
	}
	if texture := b.textures[handle.ID]; texture != nil {
		return texture, nil
	}
	if store == nil {
		return nil, fmt.Errorf("texture %d is not available without an engine texture store", handle.ID)
	}
	source, ok := store.Image(handle)
	if !ok {
		return nil, fmt.Errorf("texture %d is not registered", handle.ID)
	}
	decoded := image.NewNRGBA(image.Rect(0, 0, source.Width, source.Height))
	copy(decoded.Pix, source.Pixels)
	texture := ebiten.NewImageFromImage(decoded)
	b.textures[handle.ID] = texture
	b.textureUploads++
	return texture, nil
}

func (b *RenderBackend) renderTarget(store *render.TextureStore, target render.RenderTarget) (*ebiten.Image, error) {
	if target.Texture.ID == 0 {
		return nil, fmt.Errorf("render target must not be zero")
	}
	if cached := b.renderTargets[target.Texture.ID]; cached != nil {
		return cached, nil
	}
	if store == nil {
		return nil, fmt.Errorf("render target %d is not available without an engine texture store", target.Texture.ID)
	}
	source, ok := store.TargetImage(target)
	if !ok {
		return nil, fmt.Errorf("render target texture %d is not registered", target.Texture.ID)
	}
	decoded := image.NewNRGBA(image.Rect(0, 0, source.Width, source.Height))
	copy(decoded.Pix, source.Pixels)
	destination := ebiten.NewImageFromImage(decoded)
	b.renderTargets[target.Texture.ID] = destination
	b.textureUploads++
	return destination, nil
}

func (b *RenderBackend) cacheStats() (uint64, uint64) {
	var entries, bytes uint64
	add := func(image *ebiten.Image) {
		if image == nil {
			return
		}
		bounds := image.Bounds()
		entries++
		bytes += uint64(bounds.Dx()) * uint64(bounds.Dy()) * 4
	}
	for _, texture := range b.textures {
		add(texture)
	}
	for _, target := range b.renderTargets {
		add(target)
	}
	for _, page := range b.atlasTextures {
		add(page.image)
	}
	return entries, bytes
}

func translateRect(value render.Rect, offset render.Vec2) render.Rect {
	value.X += offset.X
	value.Y += offset.Y
	return value
}

func renderColor(value render.Color) color.RGBA {
	return color.RGBA{R: value.R, G: value.G, B: value.B, A: value.A}
}

var _ render.Backend = (*RenderBackend)(nil)
var _ render.TargetBackend = (*RenderBackend)(nil)
