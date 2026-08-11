package ecs

import (
	"errors"
	"reflect"
	"testing"
)

type position struct{ X int }
type velocity struct{ X int }

func TestWorldStoresTypedComponentsResourcesAndStableQueries(t *testing.T) {
	world := NewWorld()
	first, second, third := world.Spawn(), world.Spawn(), world.Spawn()
	if err := Add(world, second, position{X: 2}); err != nil {
		t.Fatal(err)
	}
	if err := Add(world, first, position{X: 1}); err != nil {
		t.Fatal(err)
	}
	if err := Add(world, first, velocity{X: 4}); err != nil {
		t.Fatal(err)
	}
	if err := Add(world, third, position{X: 3}); err != nil {
		t.Fatal(err)
	}
	if !world.Despawn(second) {
		t.Fatal("despawn did not remove a live entity")
	}
	var positions []int
	Each(world, func(_ Entity, value position) { positions = append(positions, value.X) })
	if want := []int{1, 3}; !reflect.DeepEqual(positions, want) {
		t.Fatalf("stable component iteration = %v, want %v", positions, want)
	}
	Each2(world, func(entity Entity, _ position, value velocity) {
		if entity != first || value.X != 4 {
			t.Fatalf("component join = entity %d velocity %+v", entity, value)
		}
	})
	SetResource(world, "ready")
	if state, ok := Resource[string](world); !ok || state != "ready" {
		t.Fatalf("resource = %q, %t", state, ok)
	}
	if err := Add(world, first, position{}); err == nil {
		t.Fatal("duplicate component succeeded")
	}
}

func TestSchedulePreservesOrderAndStopsOnError(t *testing.T) {
	world, schedule := NewWorld(), NewSchedule()
	var calls []string
	if err := schedule.Add(Update, "first", func(*World) error { calls = append(calls, "first"); return nil }); err != nil {
		t.Fatal(err)
	}
	if err := schedule.Add(Update, "second", func(*World) error { calls = append(calls, "second"); return errors.New("stop") }); err != nil {
		t.Fatal(err)
	}
	if err := schedule.Add(Update, "third", func(*World) error { calls = append(calls, "third"); return nil }); err != nil {
		t.Fatal(err)
	}
	if err := schedule.Run(Update, world); err == nil {
		t.Fatal("schedule accepted an erroring system")
	}
	if want := []string{"first", "second"}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("schedule calls = %v, want %v", calls, want)
	}
}

func TestScheduleValidatesDeclaredAccessAndExplicitOrder(t *testing.T) {
	world, schedule := NewWorld(), NewSchedule()
	var calls []string
	if err := schedule.AddSystem(Update, SystemSpec{
		Name:   "reader",
		Access: Access{Reads: []Target{ComponentTarget[position]()}},
		Run:    func(*World) error { calls = append(calls, "reader"); return nil },
	}); err != nil {
		t.Fatal(err)
	}
	if err := schedule.AddSystem(Update, SystemSpec{
		Name:   "writer",
		Access: Access{Writes: []Target{ComponentTarget[position]()}},
		Before: []string{"reader"},
		Run:    func(*World) error { calls = append(calls, "writer"); return nil },
	}); err != nil {
		t.Fatal(err)
	}
	if got, want := schedule.Names(Update), []string{"writer", "reader"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("resolved names = %v, want %v", got, want)
	}
	if err := schedule.Run(Update, world); err != nil {
		t.Fatal(err)
	}
	if want := []string{"writer", "reader"}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("ordered calls = %v, want %v", calls, want)
	}
	readOnly := NewSchedule()
	for _, name := range []string{"first-reader", "second-reader"} {
		if err := readOnly.AddSystem(Update, SystemSpec{
			Name:   name,
			Access: Access{Reads: []Target{ComponentTarget[velocity]()}},
			Run:    func(*World) error { return nil },
		}); err != nil {
			t.Fatalf("read-only overlap should validate: %v", err)
		}
	}
	if err := readOnly.Validate(Update); err != nil {
		t.Fatalf("validate read-only overlap: %v", err)
	}

	conflicting := NewSchedule()
	if err := conflicting.AddSystem(Update, SystemSpec{
		Name:   "write-resource",
		Access: Access{Writes: []Target{ResourceTarget[string]()}},
		Run:    func(*World) error { return nil },
	}); err != nil {
		t.Fatal(err)
	}
	if err := conflicting.AddSystem(Update, SystemSpec{
		Name:   "read-resource",
		Access: Access{Reads: []Target{ResourceTarget[string]()}},
		Run:    func(*World) error { return nil },
	}); err == nil {
		t.Fatal("unordered read/write conflict succeeded")
	}
	if err := conflicting.AddSystem(Update, SystemSpec{Name: "write-resource", Run: func(*World) error { return nil }}); err == nil {
		t.Fatal("duplicate system name succeeded")
	}
}
