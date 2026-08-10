package scene

import (
	"math"
	"testing"

	"github.com/gongahkia/72/engine/ecs"
)

func TestPropagateComposesParentTransforms(t *testing.T) {
	world := ecs.NewWorld()
	parent, err := New(world)
	if err != nil {
		t.Fatal(err)
	}
	child, err := New(world)
	if err != nil {
		t.Fatal(err)
	}
	if err := ecs.Set(world, parent, Transform{Position: Vec2{X: 10, Y: 4}, Rotation: math.Pi / 2, Scale: Vec2{X: 2, Y: 3}}); err != nil {
		t.Fatal(err)
	}
	if err := ecs.Set(world, child, Transform{Position: Vec2{X: 2}, Scale: Vec2{X: 2, Y: 1}}); err != nil {
		t.Fatal(err)
	}
	if err := SetParent(world, child, parent); err != nil {
		t.Fatal(err)
	}
	if err := Propagate(world); err != nil {
		t.Fatal(err)
	}
	global, ok := ecs.Get[GlobalTransform](world, child)
	if !ok || math.Abs(global.Position.X-10) > .001 || math.Abs(global.Position.Y-8) > .001 || global.Scale != (Vec2{X: 4, Y: 3}) {
		t.Fatalf("global child transform = %+v", global)
	}
	if err := SetParent(world, parent, child); err == nil {
		t.Fatal("cycle-producing parent relation succeeded")
	}
}
