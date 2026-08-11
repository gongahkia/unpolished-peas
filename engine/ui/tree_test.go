package ui

import (
	"testing"

	"github.com/gongahkia/72/engine/render"
)

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

func TestTreeCapturesPointerAndTraversesKeyboardFocus(t *testing.T) {
	tree := NewTree(Style{Direction: Row})
	first, err := tree.Add(tree.Root(), Style{Grow: 1, Interactive: true}, nil)
	if err != nil {
		t.Fatal(err)
	}
	second, err := tree.Add(tree.Root(), Style{Grow: 1, Interactive: true}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := tree.Layout(Vec2{X: 20, Y: 10}); err != nil {
		t.Fatal(err)
	}
	if target, ok := tree.DispatchPointer(PointerEvent{Position: Vec2{X: 2, Y: 2}, Pressed: true}); !ok || target != first {
		t.Fatalf("pressed target = %d, %t", target, ok)
	}
	if capture, ok := tree.PointerCapture(); !ok || capture != first {
		t.Fatalf("capture = %d, %t", capture, ok)
	}
	if target, ok := tree.DispatchPointer(PointerEvent{Position: Vec2{X: 19, Y: 9}, Released: true}); !ok || target != first {
		t.Fatalf("released target = %d, %t", target, ok)
	}
	if _, ok := tree.PointerCapture(); ok {
		t.Fatal("release retained pointer capture")
	}
	if target, ok := tree.DispatchKeyboard(KeyboardInput{FocusNext: true}); !ok || target != second {
		t.Fatalf("next focus = %d, %t", target, ok)
	}
	if target, ok := tree.DispatchKeyboard(KeyboardInput{Activate: true}); !ok || target != second {
		t.Fatalf("activated target = %d, %t", target, ok)
	}
	if target, ok := tree.DispatchKeyboard(KeyboardInput{FocusPrevious: true}); !ok || target != first {
		t.Fatalf("previous focus = %d, %t", target, ok)
	}
	if target, ok := tree.DispatchKeyboard(KeyboardInput{FocusPrevious: true}); !ok || target != second {
		t.Fatalf("wrapped previous focus = %d, %t", target, ok)
	}
	if target, ok := tree.DispatchPointer(PointerEvent{Position: Vec2{X: 12, Y: 2}, Pressed: true}); !ok || target != second {
		t.Fatalf("second press target = %d, %t", target, ok)
	}
	tree.CancelPointer()
	if _, ok := tree.PointerCapture(); ok {
		t.Fatal("cancel retained pointer capture")
	}
}

func TestTreeRendersVisualContentInPainterOrder(t *testing.T) {
	tree := NewTree(Style{Direction: Row})
	background := render.Color{B: 255, A: 255}
	label := render.Color{R: 255, G: 255, B: 255, A: 255}
	if err := tree.SetContent(tree.Root(), Visual{DrawFill: true, Fill: background}); err != nil {
		t.Fatal(err)
	}
	if _, err := tree.Add(tree.Root(), Style{Grow: 1}, Visual{BorderWidth: 1, Border: label, Text: "OK", TextColor: label, TextPosition: Vec2{X: 1, Y: 13}}); err != nil {
		t.Fatal(err)
	}
	if err := tree.Layout(Vec2{X: 20, Y: 16}); err != nil {
		t.Fatal(err)
	}
	var queue render.Queue
	if err := tree.Render(queueRenderer{queue: &queue, layer: 7}); err != nil {
		t.Fatal(err)
	}
	commands := queue.Commands()
	if len(commands) != 3 {
		t.Fatalf("command count = %d, want 3", len(commands))
	}
	for index, want := range []render.CommandKind{render.FillRect, render.StrokeRect, render.Text} {
		if commands[index].Kind != want || commands[index].Layer != 7 || commands[index].Space != render.ScreenSpace {
			t.Fatalf("command %d = %+v", index, commands[index])
		}
	}
	backend, err := render.NewReferenceBackend(20, 16)
	if err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(render.Frame{Queue: &queue}); err != nil {
		t.Fatal(err)
	}
	image := backend.Snapshot()
	if got := image.Pixels[0:4]; got[2] != 255 || got[3] != 255 {
		t.Fatalf("background pixel = %v", got)
	}
}

func TestTreeClipsDescendantVisualsToAncestorBounds(t *testing.T) {
	tree := NewTree(Style{Direction: Column})
	parent, err := tree.Add(tree.Root(), Style{Width: 4, Height: 4, Direction: Row}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tree.Add(parent, Style{Width: 8, Height: 4}, Visual{DrawFill: true, Fill: render.Color{R: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := tree.Layout(Vec2{X: 8, Y: 4}); err != nil {
		t.Fatal(err)
	}
	var queue render.Queue
	if err := tree.Render(queueRenderer{queue: &queue, layer: 0}); err != nil {
		t.Fatal(err)
	}
	backend, err := render.NewReferenceBackend(8, 4)
	if err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(render.Frame{Queue: &queue}); err != nil {
		t.Fatal(err)
	}
	image := backend.Snapshot()
	if got := image.Pixels[3*4 : 3*4+4]; got[0] != 255 || got[3] != 255 {
		t.Fatalf("inside ancestor clip = %v", got)
	}
	if got := image.Pixels[4*4 : 4*4+4]; got[3] != 0 {
		t.Fatalf("outside ancestor clip = %v, want transparent", got)
	}
}

func TestTreeRequiresClipCommandRenderer(t *testing.T) {
	tree := NewTree(Style{})
	if err := tree.Render(legacyRenderer{}); err == nil {
		t.Fatal("renderer without clip support rendered a retained tree")
	}
}

type queueRenderer struct {
	queue *render.Queue
	layer int
}

func (r queueRenderer) PushClip(bounds render.Rect) error { return r.queue.PushClip(bounds) }

func (r queueRenderer) PopClip() error { return r.queue.PopClip() }

func (r queueRenderer) FillRect(draw render.RectDraw) error {
	return r.queue.FillRect(r.layer, render.ScreenSpace, draw)
}

func (r queueRenderer) StrokeRect(draw render.RectDraw) error {
	return r.queue.StrokeRect(r.layer, render.ScreenSpace, draw)
}

func (r queueRenderer) DrawText(draw render.TextDraw) error {
	return r.queue.DrawText(r.layer, render.ScreenSpace, draw)
}

type legacyRenderer struct{}

func (legacyRenderer) FillRect(render.RectDraw) error   { return nil }
func (legacyRenderer) StrokeRect(render.RectDraw) error { return nil }
func (legacyRenderer) DrawText(render.TextDraw) error   { return nil }
