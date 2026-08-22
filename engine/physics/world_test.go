package physics

import (
	"math"
	"testing"
)

func TestWorldResolvesBodiesAndReportsStableContacts(t *testing.T) {
	world := NewWorld()
	static, err := world.Add(Body{Type: StaticBody, Shape: AABB{HalfExtents: Vec2{X: 1, Y: 1}}, Layer: 1, Mask: 1})
	if err != nil {
		t.Fatal(err)
	}
	dynamic, err := world.Add(Body{Type: DynamicBody, Position: Vec2{X: 1.5}, Velocity: Vec2{X: -1}, Shape: AABB{HalfExtents: Vec2{X: 1, Y: 1}}, Layer: 1, Mask: 1})
	if err != nil {
		t.Fatal(err)
	}
	if err := world.Step(1); err != nil {
		t.Fatal(err)
	}
	contacts := world.Contacts()
	if len(contacts) != 1 || contacts[0].First != static || contacts[0].Second != dynamic || contacts[0].State != ContactBegin {
		t.Fatalf("contacts = %+v", contacts)
	}
	body, _ := world.Get(dynamic)
	if body.Position.X != 2 || body.Velocity.X != 0 {
		t.Fatalf("dynamic body was not resolved: %+v", body)
	}
	if got := world.Overlap(AABB{HalfExtents: Vec2{X: 2, Y: 2}}, Vec2{}, 1); len(got) != 2 {
		t.Fatalf("overlap query = %v", got)
	}
}

func TestWorldTracksContactLifecycleAndFixedSteps(t *testing.T) {
	world, err := NewWorldWithConfig(Config{FixedDelta: .5})
	if err != nil {
		t.Fatal(err)
	}
	first, err := world.Add(Body{Type: DynamicBody, Velocity: Vec2{X: 1}, Shape: AABB{HalfExtents: Vec2{X: 1, Y: 1}}, Layer: 1, Mask: 1})
	if err != nil {
		t.Fatal(err)
	}
	second, err := world.Add(Body{Type: StaticBody, Position: Vec2{X: 1.5}, Shape: AABB{HalfExtents: Vec2{X: 1, Y: 1}}, Layer: 1, Mask: 1, Sensor: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := world.StepFixed(); err != nil {
		t.Fatal(err)
	}
	if contacts := world.Contacts(); len(contacts) != 1 || contacts[0].State != ContactBegin || !contacts[0].Sensor {
		t.Fatalf("begin contacts = %+v", contacts)
	}
	if moved, _ := world.Get(first); moved.Position.X != .5 {
		t.Fatalf("sensor resolved the dynamic body: %+v", moved)
	}
	if err := world.StepFixed(); err != nil {
		t.Fatal(err)
	}
	if contacts := world.Contacts(); len(contacts) != 1 || contacts[0].State != ContactStay {
		t.Fatalf("stay contacts = %+v", contacts)
	}
	if !world.Remove(second) {
		t.Fatal("remove existing body = false")
	}
	if err := world.StepFixed(); err != nil {
		t.Fatal(err)
	}
	if contacts := world.Contacts(); len(contacts) != 1 || contacts[0].State != ContactEnd || contacts[0].First != first || contacts[0].Second != second {
		t.Fatalf("end contacts = %+v", contacts)
	}
}

func TestWorldRaycastAndSweepAABBReturnNearestStableHit(t *testing.T) {
	world := NewWorld()
	first, err := world.Add(Body{Type: StaticBody, Position: Vec2{X: 4}, Shape: AABB{HalfExtents: Vec2{X: 1, Y: 1}}, Layer: 1})
	if err != nil {
		t.Fatal(err)
	}
	second, err := world.Add(Body{Type: StaticBody, Position: Vec2{X: 4, Y: 3}, Shape: AABB{HalfExtents: Vec2{X: 1, Y: 1}}, Layer: 1})
	if err != nil {
		t.Fatal(err)
	}
	hit, ok := world.Raycast(Vec2{}, Vec2{X: 10}, 1, 0)
	if !ok || hit.Body != first || hit.Fraction != .3 || hit.Point != (Vec2{X: 3}) || hit.Normal != (Vec2{X: -1}) {
		t.Fatalf("raycast = %+v, %t", hit, ok)
	}
	sweep, ok := world.SweepAABB(AABB{HalfExtents: Vec2{X: 1, Y: .5}}, Vec2{}, Vec2{X: 10}, 1, first)
	if ok || sweep != (QueryHit{}) {
		t.Fatalf("excluded sweep = %+v, %t", sweep, ok)
	}
	sweep, ok = world.SweepAABB(AABB{HalfExtents: Vec2{X: 1, Y: .5}}, Vec2{}, Vec2{X: 10}, 1, 0)
	if !ok || sweep.Body != first || sweep.Fraction != .2 || sweep.Point != (Vec2{X: 2}) || sweep.Normal != (Vec2{X: -1}) {
		t.Fatalf("sweep = %+v, %t", sweep, ok)
	}
	if _, ok := world.Raycast(Vec2{}, Vec2{X: 10}, 1, first); ok {
		t.Fatal("excluded raycast hit")
	}
	if hit, ok := world.Raycast(Vec2{Y: 3}, Vec2{X: 10}, 1, 0); !ok || hit.Body != second {
		t.Fatalf("parallel raycast = %+v, %t", hit, ok)
	}
}

func TestWorldQueriesHandleInitialOverlapMasksAndInvalidInputWithoutMutation(t *testing.T) {
	world := NewWorld()
	id, err := world.Add(Body{Type: StaticBody, Shape: AABB{HalfExtents: Vec2{X: 1, Y: 2}}, Layer: 2, Sensor: true})
	if err != nil {
		t.Fatal(err)
	}
	before, _ := world.Get(id)
	hit, ok := world.SweepAABB(AABB{HalfExtents: Vec2{X: .5, Y: .5}}, Vec2{}, Vec2{X: 1}, 2, 0)
	if !ok || hit.Body != id || hit.Fraction != 0 || hit.Normal != (Vec2{X: 1}) {
		t.Fatalf("initial overlap = %+v, %t", hit, ok)
	}
	if after, _ := world.Get(id); after != before || len(world.Contacts()) != 0 {
		t.Fatalf("query mutated world: body=%+v contacts=%+v", after, world.Contacts())
	}
	for _, query := range []struct {
		origin, delta Vec2
		mask          uint32
	}{
		{Vec2{}, Vec2{}, 2},
		{Vec2{}, Vec2{X: 1}, 0},
		{Vec2{X: math.NaN()}, Vec2{X: 1}, 2},
	} {
		if _, ok := world.Raycast(query.origin, query.delta, query.mask, 0); ok {
			t.Fatalf("invalid raycast succeeded: %+v", query)
		}
	}
}
