// Package ecs provides a deterministic, data-oriented entity component world.
package ecs

import (
	"fmt"
	"reflect"
)

// Entity identifies one live object in a World. Entity zero is never valid.
type Entity uint64

// World owns entities, components, and singleton resources. Component iteration
// is stable by entity creation order so systems do not inherit Go map ordering.
type World struct {
	next       Entity
	alive      map[Entity]struct{}
	components map[reflect.Type]map[Entity]any
	resources  map[reflect.Type]any
}

// NewWorld creates an empty component world.
func NewWorld() *World {
	return &World{
		next:       1,
		alive:      make(map[Entity]struct{}),
		components: make(map[reflect.Type]map[Entity]any),
		resources:  make(map[reflect.Type]any),
	}
}

// Spawn creates and returns a live entity.
func (w *World) Spawn() Entity {
	entity := w.next
	w.next++
	w.alive[entity] = struct{}{}
	return entity
}

// Alive reports whether entity belongs to the world and has not been despawned.
func (w *World) Alive(entity Entity) bool {
	_, ok := w.alive[entity]
	return ok
}

// Despawn removes an entity and every component attached to it.
func (w *World) Despawn(entity Entity) bool {
	if !w.Alive(entity) {
		return false
	}
	delete(w.alive, entity)
	for _, store := range w.components {
		delete(store, entity)
	}
	return true
}

// Add attaches a component to a live entity. Replacing an existing component is
// explicit through Set so accidental duplicate composition is an error.
func Add[T any](w *World, entity Entity, component T) error {
	if !w.Alive(entity) {
		return fmt.Errorf("entity %d is not alive", entity)
	}
	typeID := typeOf[T]()
	store := w.components[typeID]
	if store == nil {
		store = make(map[Entity]any)
		w.components[typeID] = store
	}
	if _, exists := store[entity]; exists {
		return fmt.Errorf("entity %d already has component %s", entity, typeID)
	}
	store[entity] = component
	return nil
}

// Set attaches or replaces a component on a live entity.
func Set[T any](w *World, entity Entity, component T) error {
	if !w.Alive(entity) {
		return fmt.Errorf("entity %d is not alive", entity)
	}
	typeID := typeOf[T]()
	store := w.components[typeID]
	if store == nil {
		store = make(map[Entity]any)
		w.components[typeID] = store
	}
	store[entity] = component
	return nil
}

// Get returns entity's component of type T.
func Get[T any](w *World, entity Entity) (T, bool) {
	var zero T
	store := w.components[typeOf[T]()]
	if store == nil {
		return zero, false
	}
	value, ok := store[entity]
	if !ok {
		return zero, false
	}
	component, ok := value.(T)
	return component, ok
}

// Has reports whether entity has a component of type T.
func Has[T any](w *World, entity Entity) bool {
	_, ok := Get[T](w, entity)
	return ok
}

// Remove detaches a component from an entity and reports whether it was present.
func Remove[T any](w *World, entity Entity) bool {
	store := w.components[typeOf[T]()]
	if store == nil {
		return false
	}
	if _, exists := store[entity]; !exists {
		return false
	}
	delete(store, entity)
	return true
}

// Each visits all live entities with T in stable entity order. To modify a
// component, call Set from the callback with the replacement value.
func Each[T any](w *World, visit func(Entity, T)) {
	for entity := Entity(1); entity < w.next; entity++ {
		if !w.Alive(entity) {
			continue
		}
		if component, ok := Get[T](w, entity); ok {
			visit(entity, component)
		}
	}
}

// Each2 visits all live entities that have both component types in stable
// entity order.
func Each2[A, B any](w *World, visit func(Entity, A, B)) {
	for entity := Entity(1); entity < w.next; entity++ {
		if !w.Alive(entity) {
			continue
		}
		first, firstOK := Get[A](w, entity)
		second, secondOK := Get[B](w, entity)
		if firstOK && secondOK {
			visit(entity, first, second)
		}
	}
}

// SetResource stores a singleton resource of type T.
func SetResource[T any](w *World, resource T) { w.resources[typeOf[T]()] = resource }

// Resource returns a singleton resource of type T.
func Resource[T any](w *World) (T, bool) {
	var zero T
	resource, ok := w.resources[typeOf[T]()]
	if !ok {
		return zero, false
	}
	value, ok := resource.(T)
	return value, ok
}

// RemoveResource removes a singleton resource of type T.
func RemoveResource[T any](w *World) bool {
	typeID := typeOf[T]()
	if _, exists := w.resources[typeID]; !exists {
		return false
	}
	delete(w.resources, typeID)
	return true
}

func typeOf[T any]() reflect.Type { return reflect.TypeOf((*T)(nil)).Elem() }
