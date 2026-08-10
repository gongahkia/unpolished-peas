package ui

import "testing"

func TestTreeLayoutsAndTargetsFrontmostInteractiveNode(t *testing.T) {
	tree := NewTree(Style{Direction: Row, Padding: 10, Gap: 10})
	left, err := tree.Add(tree.Root(), Style{Grow: 1, Interactive: true}, "left")
	if err != nil {
		t.Fatal(err)
	}
	right, err := tree.Add(tree.Root(), Style{Grow: 1, Interactive: true}, "right")
	if err != nil {
		t.Fatal(err)
	}
	if err := tree.Layout(Vec2{X: 110, Y: 50}); err != nil {
		t.Fatal(err)
	}
	leftNode, _ := tree.Node(left)
	rightNode, _ := tree.Node(right)
	if leftNode.Bounds != (Rect{X: 10, Y: 10, W: 40, H: 30}) || rightNode.Bounds != (Rect{X: 60, Y: 10, W: 40, H: 30}) {
		t.Fatalf("layout left=%+v right=%+v", leftNode.Bounds, rightNode.Bounds)
	}
	if target, ok := tree.DispatchPointer(PointerEvent{Position: Vec2{X: 70, Y: 20}, Pressed: true}); !ok || target != right {
		t.Fatalf("pointer target = %d, %t", target, ok)
	}
	if focus, ok := tree.Focus(); !ok || focus != right {
		t.Fatalf("focus = %d, %t", focus, ok)
	}
}
