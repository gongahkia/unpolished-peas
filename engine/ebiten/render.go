package ebiten

import (
	"fmt"
	"image"
	"image/color"
	"sort"

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
	target   *ebiten.Image
	nextID   uint64
	textures map[uint64]*ebiten.Image
}

// NewRenderBackend creates a temporary renderer for target.
func NewRenderBackend(target *ebiten.Image) *RenderBackend {
	return &RenderBackend{target: target, textures: make(map[uint64]*ebiten.Image)}
}

// SetTarget updates the Ebitengine target used for subsequent Render calls.
func (b *RenderBackend) SetTarget(target *ebiten.Image) { b.target = target }

// CreateTexture registers source and returns an opaque engine/render texture.
func (b *RenderBackend) CreateTexture(source image.Image) (render.Texture, error) {
	if source == nil {
		return render.Texture{}, fmt.Errorf("texture source must not be nil")
	}
	b.nextID++
	b.textures[b.nextID] = ebiten.NewImageFromImage(source)
	return render.Texture{ID: b.nextID}, nil
}

// Render submits a high-level 2D frame to the configured Ebitengine target.
func (b *RenderBackend) Render(frame render.Frame) error {
	if b.target == nil {
		return fmt.Errorf("Ebitengine render target must not be nil")
	}
	if frame.Queue == nil {
		return fmt.Errorf("render frame queue must not be nil")
	}
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
		if err := b.draw(frame.Camera, command); err != nil {
			return err
		}
	}
	return nil
}

func (b *RenderBackend) draw(camera render.Camera, command render.Command) error {
	translate := render.Vec2{}
	if command.Space == render.WorldSpace {
		translate = render.Vec2{X: -camera.Position.X, Y: -camera.Position.Y}
	}
	switch command.Kind {
	case render.SpriteCommand:
		value, ok := command.Payload.(render.Sprite)
		if !ok {
			return fmt.Errorf("sprite command has payload %T", command.Payload)
		}
		return b.drawSprite(value, translate)
	case render.TileMapCommand:
		value, ok := command.Payload.(render.TileMap)
		if !ok {
			return fmt.Errorf("tile map command has payload %T", command.Payload)
		}
		return b.drawTileMap(value, translate)
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
		text.Draw(b.target, value.Value, basicfont.Face7x13, int(value.Position.X+translate.X), int(value.Position.Y+translate.Y), renderColor(value.Color))
	default:
		return fmt.Errorf("unsupported render command %d", command.Kind)
	}
	return nil
}

func (b *RenderBackend) drawSprite(sprite render.Sprite, translate render.Vec2) error {
	texture := b.textures[sprite.Texture.ID]
	if texture == nil {
		return fmt.Errorf("texture %d is not registered", sprite.Texture.ID)
	}
	source := sprite.Source
	if source.W == 0 && source.H == 0 {
		bounds := texture.Bounds()
		source = render.Rect{W: float64(bounds.Dx()), H: float64(bounds.Dy())}
	}
	if source.W <= 0 || source.H <= 0 {
		return fmt.Errorf("sprite source must be positive")
	}
	image := texture.SubImage(image.Rect(int(source.X), int(source.Y), int(source.X+source.W), int(source.Y+source.H))).(*ebiten.Image)
	op := &ebiten.DrawImageOptions{}
	op.Filter = ebiten.FilterNearest
	op.GeoM.Scale(sprite.Bounds.W/source.W, sprite.Bounds.H/source.H)
	op.GeoM.Translate(sprite.Bounds.X+translate.X, sprite.Bounds.Y+translate.Y)
	op.ColorScale.Scale(float32(sprite.Tint.R)/255, float32(sprite.Tint.G)/255, float32(sprite.Tint.B)/255, float32(sprite.Tint.A)/255)
	b.target.DrawImage(image, op)
	return nil
}

func (b *RenderBackend) drawTileMap(tiles render.TileMap, translate render.Vec2) error {
	texture := b.textures[tiles.Texture.ID]
	if texture == nil {
		return fmt.Errorf("texture %d is not registered", tiles.Texture.ID)
	}
	for index, tile := range tiles.Tiles {
		if tile < 0 {
			continue
		}
		column, row := index%tiles.Columns, index/tiles.Columns
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
		if err := b.drawSprite(sprite, translate); err != nil {
			return err
		}
	}
	return nil
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
