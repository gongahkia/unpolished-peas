package engine

import (
	"fmt"
	"math"
	"sort"

	"github.com/gongahkia/72/engine/render"
)

// Frame is the context supplied to a layer draw callback.
type Frame struct {
	Canvas   Canvas
	Camera   Camera
	Tick     uint64
	Viewport Size
}

// DrawFunc renders one layer for a frame.
type DrawFunc func(Frame)

// CommandFrame is the context supplied to a high-level render command layer.
// Its methods use the Layer's registered order and space automatically.
type CommandFrame struct {
	Camera   Camera
	Tick     uint64
	Viewport Size

	queue *render.Queue
	order int
	space render.Space
}

// Clear records a screen-space frame clear. It is valid only on a screen-space
// layer because world-space clears have no meaningful camera transform.
func (f CommandFrame) Clear(color render.Color) error {
	if f.space != render.ScreenSpace {
		return fmt.Errorf("clear is only valid on a screen-space command layer")
	}
	f.queue.Clear(color)
	return nil
}

// DrawSprite records a textured quad in the layer's space and order.
func (f CommandFrame) DrawSprite(sprite render.Sprite) error {
	return f.queue.DrawSprite(f.order, f.space, sprite)
}

// DrawTileMap records a tile map in the layer's space and order.
func (f CommandFrame) DrawTileMap(tiles render.TileMap) error {
	return f.queue.DrawTileMap(f.order, f.space, tiles)
}

// FillRect records a filled rectangle in the layer's space and order.
func (f CommandFrame) FillRect(draw render.RectDraw) error {
	return f.queue.FillRect(f.order, f.space, draw)
}

// StrokeRect records a stroked rectangle in the layer's space and order.
func (f CommandFrame) StrokeRect(draw render.RectDraw) error {
	return f.queue.StrokeRect(f.order, f.space, draw)
}

// FillCircle records a filled circle in the layer's space and order.
func (f CommandFrame) FillCircle(draw render.CircleDraw) error {
	return f.queue.FillCircle(f.order, f.space, draw)
}

// StrokeLine records a stroked line in the layer's space and order.
func (f CommandFrame) StrokeLine(draw render.LineDraw) error {
	return f.queue.StrokeLine(f.order, f.space, draw)
}

// DrawText records text in the layer's space and order.
func (f CommandFrame) DrawText(draw render.TextDraw) error {
	return f.queue.DrawText(f.order, f.space, draw)
}

// CommandDrawFunc records high-level 2D rendering for one layer.
type CommandDrawFunc func(CommandFrame) error

// Layer declares one ordered render callback.
type Layer struct {
	ID           string
	Order        int
	Space        Space
	Parallax     float64
	Draw         DrawFunc
	DrawCommands CommandDrawFunc
}

type registeredLayer struct {
	layer Layer
	index uint64
}

// LayerStack manages an arbitrary number of ordered render layers.
type LayerStack struct {
	layers []registeredLayer
	next   uint64
}

// Add registers a layer. IDs must be unique. Equal orders retain registration
// order, making independently-added layers deterministic.
func (s *LayerStack) Add(layer Layer) error {
	if layer.ID == "" {
		return fmt.Errorf("layer ID must not be empty")
	}
	if layer.Draw == nil && layer.DrawCommands == nil {
		return fmt.Errorf("layer %q has no draw callback", layer.ID)
	}
	if layer.Space != WorldSpace && layer.Space != ScreenSpace {
		return fmt.Errorf("layer %q has invalid space %d", layer.ID, layer.Space)
	}
	if layer.Space == WorldSpace && (layer.Parallax <= 0 || math.IsNaN(layer.Parallax) || math.IsInf(layer.Parallax, 0)) {
		return fmt.Errorf("world layer %q has invalid parallax %g", layer.ID, layer.Parallax)
	}
	for _, registered := range s.layers {
		if registered.layer.ID == layer.ID {
			return fmt.Errorf("layer %q is already registered", layer.ID)
		}
	}
	if layer.Space == ScreenSpace {
		layer.Parallax = 1
	}
	s.layers = append(s.layers, registeredLayer{layer: layer, index: s.next})
	s.next++
	sort.SliceStable(s.layers, func(i, j int) bool {
		if s.layers[i].layer.Order == s.layers[j].layer.Order {
			return s.layers[i].index < s.layers[j].index
		}
		return s.layers[i].layer.Order < s.layers[j].layer.Order
	})
	return nil
}

// Remove unregisters a layer by ID and reports whether it was present.
func (s *LayerStack) Remove(id string) bool {
	for index, registered := range s.layers {
		if registered.layer.ID != id {
			continue
		}
		s.layers = append(s.layers[:index], s.layers[index+1:]...)
		return true
	}
	return false
}

// SetOrder changes an existing layer's order while retaining its registration
// ordering relative to layers with equal order.
func (s *LayerStack) SetOrder(id string, order int) error {
	for index := range s.layers {
		if s.layers[index].layer.ID != id {
			continue
		}
		s.layers[index].layer.Order = order
		sort.SliceStable(s.layers, func(i, j int) bool {
			if s.layers[i].layer.Order == s.layers[j].layer.Order {
				return s.layers[i].index < s.layers[j].index
			}
			return s.layers[i].layer.Order < s.layers[j].layer.Order
		})
		return nil
	}
	return fmt.Errorf("layer %q is not registered", id)
}

// Layers returns a copy of the stack in render order.
func (s *LayerStack) Layers() []Layer {
	layers := make([]Layer, len(s.layers))
	for index, registered := range s.layers {
		layers[index] = registered.layer
	}
	return layers
}

func (s *LayerStack) draw(canvas Canvas, camera Camera, tick uint64, textures *render.TextureStore) error {
	for _, registered := range s.layers {
		layer := registered.layer
		translate := Vec2{}
		if layer.Space == WorldSpace {
			translate = Vec2{
				X: -camera.position.X*layer.Parallax + camera.offset.X*layer.Parallax,
				Y: -camera.position.Y*layer.Parallax + camera.offset.Y*layer.Parallax,
			}
		}
		if layer.Draw != nil {
			layer.Draw(Frame{Canvas: transformCanvas{canvas: canvas, translate: translate}, Camera: camera, Tick: tick, Viewport: camera.viewport})
		}
		if layer.DrawCommands == nil {
			continue
		}
		queue := &render.Queue{}
		space := render.ScreenSpace
		commandCamera := render.Camera{Viewport: render.Vec2{X: camera.viewport.W, Y: camera.viewport.H}}
		if layer.Space == WorldSpace {
			space = render.WorldSpace
			commandCamera.Position = render.Vec2{
				X: camera.position.X*layer.Parallax - camera.offset.X*layer.Parallax,
				Y: camera.position.Y*layer.Parallax - camera.offset.Y*layer.Parallax,
			}
		}
		frame := CommandFrame{Camera: camera, Tick: tick, Viewport: camera.viewport, queue: queue, order: layer.Order, space: space}
		if err := layer.DrawCommands(frame); err != nil {
			return fmt.Errorf("draw command layer %q: %w", layer.ID, err)
		}
		if len(queue.Commands()) == 0 {
			continue
		}
		commandCanvas, ok := canvas.(CommandCanvas)
		if !ok {
			return fmt.Errorf("layer %q requires a backend with high-level render command support", layer.ID)
		}
		if err := commandCanvas.RenderCommands(render.Frame{Camera: commandCamera, Queue: queue, Textures: textures}); err != nil {
			return fmt.Errorf("submit command layer %q: %w", layer.ID, err)
		}
	}
	return nil
}
