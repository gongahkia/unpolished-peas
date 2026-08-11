// Package ui provides retained 2D UI layout, focus, hit testing, and optional
// command-frame visual emission. Widget behavior remains application-owned.
package ui

import (
	"fmt"
	"math"

	"github.com/gongahkia/72/engine/render"
)

// NodeID identifies a node in a Tree. Root is always node one.
type NodeID uint64

// Vec2 is a two-dimensional UI coordinate.
type Vec2 struct{ X, Y float64 }

// Rect is a UI rectangle in screen coordinates.
type Rect struct{ X, Y, W, H float64 }

// Contains reports whether point is inside r.
func (r Rect) Contains(point Vec2) bool {
	return point.X >= r.X && point.X <= r.X+r.W && point.Y >= r.Y && point.Y <= r.Y+r.H
}

// Direction controls how a node lays out its children.
type Direction uint8

const (
	Row Direction = iota
	Column
)

// Style is a compact retained-layout style. A non-positive Width or Height
// fills the parent's available inner size along that axis.
type Style struct {
	Width, Height float64
	Padding       float64
	Gap           float64
	Direction     Direction
	Grow          float64
	Interactive   bool
}

// Node is a retained UI element. Content is application data for a renderer;
// the layout tree does not interpret it.
type Node struct {
	ID       NodeID
	Parent   NodeID
	Children []NodeID
	Style    Style
	Bounds   Rect
	Content  any
}

// PointerEvent describes a pointer press/release targeted by HitTest.
type PointerEvent struct {
	Position Vec2
	Pressed  bool
	Released bool
}

// KeyboardInput describes one normalized UI keyboard action. Applications map
// their portable engine actions to these fields; ui does not receive native key
// codes or retain an engine input snapshot.
type KeyboardInput struct {
	FocusNext     bool
	FocusPrevious bool
	Activate      bool
}

// Visual is optional node content that Tree can render through a command frame.
// TextPosition is an offset from the node's top-left corner and uses text
// baseline coordinates. A visual with zero-valued fields emits no commands.
// Content values of any other type remain application-owned and are ignored by
// Render.
type Visual struct {
	Fill         render.Color
	DrawFill     bool
	Border       render.Color
	BorderWidth  float64
	Text         string
	TextColor    render.Color
	TextPosition Vec2
}

// CommandRenderer is the subset of a command frame needed to render Visual
// content. engine.CommandFrame implements it while retaining layer and space
// ownership inside the engine package.
type CommandRenderer interface {
	FillRect(render.RectDraw) error
	StrokeRect(render.RectDraw) error
	DrawText(render.TextDraw) error
}

// Tree owns retained UI nodes.
type Tree struct {
	next    NodeID
	nodes   map[NodeID]*Node
	focus   NodeID
	capture NodeID
}

// NewTree creates a tree with one root node.
func NewTree(style Style) *Tree {
	root := &Node{ID: 1, Style: style}
	return &Tree{next: 2, nodes: map[NodeID]*Node{root.ID: root}}
}

// Root returns the immutable root identity.
func (t *Tree) Root() NodeID { return 1 }

// Add creates a child node.
func (t *Tree) Add(parent NodeID, style Style, content any) (NodeID, error) {
	container := t.nodes[parent]
	if container == nil {
		return 0, fmt.Errorf("UI parent %d does not exist", parent)
	}
	id := t.next
	t.next++
	t.nodes[id] = &Node{ID: id, Parent: parent, Style: style, Content: content}
	container.Children = append(container.Children, id)
	return id, nil
}

// Node returns a copy of retained node state.
func (t *Tree) Node(id NodeID) (Node, bool) {
	node := t.nodes[id]
	if node == nil {
		return Node{}, false
	}
	copy := *node
	copy.Children = append([]NodeID(nil), node.Children...)
	return copy, true
}

// SetStyle replaces a node's layout style.
func (t *Tree) SetStyle(id NodeID, style Style) error {
	node := t.nodes[id]
	if node == nil {
		return fmt.Errorf("UI node %d does not exist", id)
	}
	node.Style = style
	return nil
}

// SetContent replaces application-defined rendering/content data.
func (t *Tree) SetContent(id NodeID, content any) error {
	node := t.nodes[id]
	if node == nil {
		return fmt.Errorf("UI node %d does not exist", id)
	}
	node.Content = content
	return nil
}

// Layout calculates screen-space bounds from viewport.
func (t *Tree) Layout(viewport Vec2) error {
	if viewport.X < 0 || viewport.Y < 0 {
		return fmt.Errorf("UI viewport must not be negative")
	}
	root := t.nodes[t.Root()]
	root.Bounds = Rect{W: viewport.X, H: viewport.Y}
	t.layoutChildren(root)
	return nil
}

// HitTest returns the front-most interactive node at point. Later siblings are
// front-most, which matches retained painter order.
func (t *Tree) HitTest(point Vec2) (NodeID, bool) { return t.hit(t.Root(), point) }

// DispatchPointer updates focus and pointer capture on a pressed interactive
// node. While captured, a release targets the captured node even when the
// pointer has moved outside its bounds. A press outside an interactive node
// clears any earlier capture without clearing keyboard focus.
func (t *Tree) DispatchPointer(event PointerEvent) (NodeID, bool) {
	if event.Pressed {
		t.capture = 0
		target, ok := t.HitTest(event.Position)
		if !ok {
			return 0, false
		}
		t.focus, t.capture = target, target
		if event.Released {
			t.capture = 0
		}
		return target, true
	}
	if t.capture != 0 {
		target := t.capture
		if event.Released {
			t.capture = 0
		}
		if node := t.nodes[target]; node != nil && node.Style.Interactive {
			return target, true
		}
		return 0, false
	}
	target, ok := t.HitTest(event.Position)
	if event.Released {
		return 0, false
	}
	return target, ok
}

// Focus returns the currently focused interactive node, if any.
func (t *Tree) Focus() (NodeID, bool) {
	if t.focus == 0 {
		return 0, false
	}
	return t.focus, true
}

// PointerCapture returns the interactive node receiving pointer events until
// release or CancelPointer, if any.
func (t *Tree) PointerCapture() (NodeID, bool) {
	if node := t.nodes[t.capture]; node != nil && node.Style.Interactive {
		return node.ID, true
	}
	return 0, false
}

// CancelPointer clears an active pointer capture. Hosts should call it when a
// platform cancels a gesture or focus is lost.
func (t *Tree) CancelPointer() { t.capture = 0 }

// FocusNext selects the next interactive node in retained painter order. It
// wraps from the final node to the first.
func (t *Tree) FocusNext() (NodeID, bool) { return t.moveFocus(1) }

// FocusPrevious selects the previous interactive node in retained painter
// order. It wraps from the first node to the final node.
func (t *Tree) FocusPrevious() (NodeID, bool) { return t.moveFocus(-1) }

// ActivateFocused returns the focused interactive node as an activation
// target. It does not invoke application callbacks.
func (t *Tree) ActivateFocused() (NodeID, bool) {
	if node := t.nodes[t.focus]; node != nil && node.Style.Interactive {
		return node.ID, true
	}
	return 0, false
}

// DispatchKeyboard applies one normalized keyboard input. Traversal has
// priority over activation when callers intentionally supply multiple fields.
func (t *Tree) DispatchKeyboard(input KeyboardInput) (NodeID, bool) {
	if input.FocusPrevious {
		return t.FocusPrevious()
	}
	if input.FocusNext {
		return t.FocusNext()
	}
	if input.Activate {
		return t.ActivateFocused()
	}
	return 0, false
}

// Render emits Visual content in retained painter order through renderer. A
// screen-space engine.CommandFrame is the intended renderer. It does not
// implement clipping; callers must keep visuals within their viewport until
// the renderer clip contract exists.
func (t *Tree) Render(renderer CommandRenderer) error {
	if renderer == nil {
		return fmt.Errorf("UI command renderer must not be nil")
	}
	return t.renderNode(renderer, t.Root())
}

func (t *Tree) layoutChildren(parent *Node) {
	if len(parent.Children) == 0 {
		return
	}
	inner := Rect{
		X: parent.Bounds.X + parent.Style.Padding,
		Y: parent.Bounds.Y + parent.Style.Padding,
		W: max(0, parent.Bounds.W-parent.Style.Padding*2),
		H: max(0, parent.Bounds.H-parent.Style.Padding*2),
	}
	mainSize := inner.H
	if parent.Style.Direction == Row {
		mainSize = inner.W
	}
	fixed, grow := parent.Style.Gap*float64(len(parent.Children)-1), 0.0
	for _, id := range parent.Children {
		child := t.nodes[id]
		length := child.Style.Height
		if parent.Style.Direction == Row {
			length = child.Style.Width
		}
		if length > 0 {
			fixed += length
		} else {
			grow += max(1, child.Style.Grow)
		}
	}
	cursor := 0.0
	available := max(0, mainSize-fixed)
	for _, id := range parent.Children {
		child := t.nodes[id]
		width, height := child.Style.Width, child.Style.Height
		if width <= 0 {
			width = inner.W
		}
		if height <= 0 {
			height = inner.H
		}
		if parent.Style.Direction == Row {
			if child.Style.Width <= 0 {
				width = available * max(1, child.Style.Grow) / grow
			}
			child.Bounds = Rect{X: inner.X + cursor, Y: inner.Y, W: width, H: height}
			cursor += width + parent.Style.Gap
		} else {
			if child.Style.Height <= 0 {
				height = available * max(1, child.Style.Grow) / grow
			}
			child.Bounds = Rect{X: inner.X, Y: inner.Y + cursor, W: width, H: height}
			cursor += height + parent.Style.Gap
		}
		t.layoutChildren(child)
	}
}

func (t *Tree) hit(id NodeID, point Vec2) (NodeID, bool) {
	node := t.nodes[id]
	if node == nil || !node.Bounds.Contains(point) {
		return 0, false
	}
	for index := len(node.Children) - 1; index >= 0; index-- {
		if target, ok := t.hit(node.Children[index], point); ok {
			return target, true
		}
	}
	if node.Style.Interactive {
		return node.ID, true
	}
	return 0, false
}

func (t *Tree) moveFocus(direction int) (NodeID, bool) {
	nodes := t.interactiveNodes(t.Root(), nil)
	if len(nodes) == 0 {
		t.focus = 0
		return 0, false
	}
	current := -1
	for index, id := range nodes {
		if id == t.focus {
			current = index
			break
		}
	}
	if current < 0 {
		if direction > 0 {
			t.focus = nodes[0]
		} else {
			t.focus = nodes[len(nodes)-1]
		}
		return t.focus, true
	}
	current = (current + direction + len(nodes)) % len(nodes)
	t.focus = nodes[current]
	return t.focus, true
}

func (t *Tree) interactiveNodes(id NodeID, nodes []NodeID) []NodeID {
	node := t.nodes[id]
	if node == nil {
		return nodes
	}
	if node.Style.Interactive {
		nodes = append(nodes, node.ID)
	}
	for _, child := range node.Children {
		nodes = t.interactiveNodes(child, nodes)
	}
	return nodes
}

func (t *Tree) renderNode(renderer CommandRenderer, id NodeID) error {
	node := t.nodes[id]
	if node == nil {
		return nil
	}
	if visual, ok := node.Content.(Visual); ok {
		if err := renderVisual(renderer, node.Bounds, visual); err != nil {
			return fmt.Errorf("render UI node %d: %w", node.ID, err)
		}
	}
	for _, child := range node.Children {
		if err := t.renderNode(renderer, child); err != nil {
			return err
		}
	}
	return nil
}

func renderVisual(renderer CommandRenderer, bounds Rect, visual Visual) error {
	if !finiteRect(bounds) || bounds.W < 0 || bounds.H < 0 {
		return fmt.Errorf("UI bounds must be finite and non-negative")
	}
	renderBounds := render.Rect{X: bounds.X, Y: bounds.Y, W: bounds.W, H: bounds.H}
	if visual.DrawFill {
		if renderBounds.W <= 0 || renderBounds.H <= 0 {
			return fmt.Errorf("filled UI visual requires positive bounds")
		}
		if err := renderer.FillRect(render.RectDraw{Bounds: renderBounds, Color: visual.Fill}); err != nil {
			return err
		}
	}
	if visual.BorderWidth != 0 {
		if !finite(visual.BorderWidth) || visual.BorderWidth < 0 {
			return fmt.Errorf("UI border width must be finite and non-negative")
		}
		if renderBounds.W <= 0 || renderBounds.H <= 0 {
			return fmt.Errorf("bordered UI visual requires positive bounds")
		}
		if err := renderer.StrokeRect(render.RectDraw{Bounds: renderBounds, Width: visual.BorderWidth, Color: visual.Border}); err != nil {
			return err
		}
	}
	if visual.Text == "" {
		return nil
	}
	if !finiteVec(visual.TextPosition) {
		return fmt.Errorf("UI text position must be finite")
	}
	return renderer.DrawText(render.TextDraw{
		Position: render.Vec2{X: bounds.X + visual.TextPosition.X, Y: bounds.Y + visual.TextPosition.Y},
		Value:    visual.Text,
		Color:    visual.TextColor,
	})
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func finiteVec(value Vec2) bool { return finite(value.X) && finite(value.Y) }

func finiteRect(value Rect) bool {
	return finite(value.X) && finite(value.Y) && finite(value.W) && finite(value.H)
}

func max(left, right float64) float64 {
	if left > right {
		return left
	}
	return right
}
