package physics

import "testing"

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
	if len(contacts) != 1 || contacts[0].First != static || contacts[0].Second != dynamic {
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
