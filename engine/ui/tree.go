// Package ui provides retained 2D UI layout, focus, and hit testing. Rendering
// is intentionally supplied by the engine render layer rather than by widgets.
package ui

import "fmt"

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

// Tree owns retained UI nodes.
type Tree struct {
	next  NodeID
	nodes map[NodeID]*Node
	focus NodeID
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

// DispatchPointer updates focus on a pressed interactive node and returns its
// target. Releases do not change focus.
func (t *Tree) DispatchPointer(event PointerEvent) (NodeID, bool) {
	target, ok := t.HitTest(event.Position)
	if ok && event.Pressed {
		t.focus = target
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

func max(left, right float64) float64 {
	if left > right {
		return left
	}
	return right
}
