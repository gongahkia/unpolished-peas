// Package engine provides a backend-neutral 2D application runtime.
package engine

import "fmt"

// Vec2 is a logical two-dimensional position.
type Vec2 struct {
	X, Y float64
}

// Size is a logical viewport size.
type Size struct {
	W, H float64
}

// Rect is an axis-aligned logical rectangle.
type Rect struct {
	X, Y, W, H float64
}

// Color is a non-premultiplied RGBA color.
type Color struct {
	R, G, B, A uint8
}

// Space determines whether a layer is transformed by the camera.
type Space uint8

const (
	// WorldSpace layers move with the camera and can use parallax.
	WorldSpace Space = iota
	// ScreenSpace layers draw in logical viewport coordinates.
	ScreenSpace
)

// Camera controls the transform applied to world-space layers. Games own
// follow, clamp, and shake policy by setting Position and Offset each update.
type Camera struct {
	position Vec2
	offset   Vec2
	viewport Size
}

// NewCamera creates a camera for a logical viewport.
func NewCamera(viewport Size) Camera { return Camera{viewport: viewport} }

// Position returns the world-space origin visible at the top-left viewport edge.
func (c Camera) Position() Vec2 { return c.position }

// Offset returns the presentation-only camera offset.
func (c Camera) Offset() Vec2 { return c.offset }

// Viewport returns the camera's logical viewport size.
func (c Camera) Viewport() Size { return c.viewport }

// SetPosition updates the world-space camera origin.
func (c *Camera) SetPosition(position Vec2) { c.position = position }

// SetOffset updates the presentation-only camera offset.
func (c *Camera) SetOffset(offset Vec2) { c.offset = offset }

// Config configures an application runtime.
type Config struct {
	Title       string
	Viewport    Size
	WindowScale int
	Actions     ActionMap
}

func (c Config) validate() error {
	if c.Viewport.W <= 0 || c.Viewport.H <= 0 {
		return fmt.Errorf("viewport must be positive, got %gx%g", c.Viewport.W, c.Viewport.H)
	}
	if c.WindowScale <= 0 {
		return fmt.Errorf("window scale must be positive, got %d", c.WindowScale)
	}
	return c.Actions.Validate()
}
