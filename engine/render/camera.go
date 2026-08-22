package render

import (
	"fmt"
	"math"
)

// cameraTransform applies a render Camera to one WorldSpace command. Screen
// commands use the identity transform.
type cameraTransform struct {
	position Vec2
	offset   Vec2
	center   Vec2
	zoom     float64
}

func newCameraTransform(camera Camera, space Space) (cameraTransform, error) {
	if space == ScreenSpace {
		return cameraTransform{zoom: 1}, nil
	}
	if space != WorldSpace {
		return cameraTransform{}, fmt.Errorf("render command has invalid space %d", space)
	}
	if !finiteVec(camera.Position) || !finiteVec(camera.Offset) || !finiteVec(camera.Viewport) {
		return cameraTransform{}, fmt.Errorf("render camera position, offset, and viewport must be finite")
	}
	zoom := camera.Zoom
	if zoom == 0 {
		zoom = 1
	}
	if math.IsNaN(zoom) || math.IsInf(zoom, 0) || zoom <= 0 {
		return cameraTransform{}, fmt.Errorf("render camera zoom must be finite and positive")
	}
	return cameraTransform{position: camera.Position, offset: camera.Offset, center: Vec2{X: camera.Viewport.X / 2, Y: camera.Viewport.Y / 2}, zoom: zoom}, nil
}

func (t cameraTransform) point(value Vec2) Vec2 {
	return Vec2{X: t.center.X + (value.X-t.position.X-t.center.X)*t.zoom + t.offset.X, Y: t.center.Y + (value.Y-t.position.Y-t.center.Y)*t.zoom + t.offset.Y}
}

func (t cameraTransform) rect(value Rect) Rect {
	point := t.point(Vec2{X: value.X, Y: value.Y})
	return Rect{X: point.X, Y: point.Y, W: value.W * t.zoom, H: value.H * t.zoom}
}

func (t cameraTransform) inversePoint(value Vec2) Vec2 {
	return Vec2{X: t.position.X + t.center.X + (value.X-t.center.X-t.offset.X)/t.zoom, Y: t.position.Y + t.center.Y + (value.Y-t.center.Y-t.offset.Y)/t.zoom}
}

func (t cameraTransform) inverseRect(value Rect) Rect {
	point := t.inversePoint(Vec2{X: value.X, Y: value.Y})
	return Rect{X: point.X, Y: point.Y, W: value.W / t.zoom, H: value.H / t.zoom}
}
