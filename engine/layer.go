package engine

import (
	"fmt"
	"math"
	"sort"
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

// Layer declares one ordered render callback.
type Layer struct {
	ID       string
	Order    int
	Space    Space
	Parallax float64
	Draw     DrawFunc
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
	if layer.Draw == nil {
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

func (s *LayerStack) draw(canvas Canvas, camera Camera, tick uint64) {
	for _, registered := range s.layers {
		layer := registered.layer
		translate := Vec2{}
		if layer.Space == WorldSpace {
			translate = Vec2{
				X: -camera.position.X*layer.Parallax + camera.offset.X*layer.Parallax,
				Y: -camera.position.Y*layer.Parallax + camera.offset.Y*layer.Parallax,
			}
		}
		layer.Draw(Frame{Canvas: transformCanvas{canvas: canvas, translate: translate}, Camera: camera, Tick: tick, Viewport: camera.viewport})
	}
}
