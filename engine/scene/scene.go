// Package scene provides an ECS-backed transform hierarchy.
package scene

import (
	"fmt"
	"math"

	"github.com/gongahkia/72/engine/ecs"
)

// Vec2 is a two-dimensional position or scale.
type Vec2 struct{ X, Y float64 }

// Transform is local to an entity's parent. Zero Scale is treated as one when
// composing so an omitted transform has an unsurprising identity scale.
type Transform struct {
	Position Vec2
	Rotation float64
	Scale    Vec2
}

// GlobalTransform is Transform resolved into world coordinates.
type GlobalTransform struct {
	Position Vec2
	Rotation float64
	Scale    Vec2
}

// Parent links an entity to another entity in the same ECS World.
type Parent struct{ Entity ecs.Entity }

// New creates an entity with an identity local and global transform.
func New(world *ecs.World) (ecs.Entity, error) {
	entity := world.Spawn()
	if err := ecs.Add(world, entity, Identity()); err != nil {
		return 0, err
	}
	if err := ecs.Add(world, entity, GlobalTransform{Scale: Vec2{X: 1, Y: 1}}); err != nil {
		return 0, err
	}
	return entity, nil
}

// Identity returns an identity local transform.
func Identity() Transform { return Transform{Scale: Vec2{X: 1, Y: 1}} }

// SetParent attaches child to parent. An entity cannot parent itself, parent a
// missing entity, or form a cycle.
func SetParent(world *ecs.World, child, parent ecs.Entity) error {
	if !world.Alive(child) || !world.Alive(parent) {
		return fmt.Errorf("child %d or parent %d is not alive", child, parent)
	}
	if child == parent {
		return fmt.Errorf("entity %d cannot parent itself", child)
	}
	for cursor := parent; ; {
		if cursor == child {
			return fmt.Errorf("parenting %d to %d would form a cycle", child, parent)
		}
		next, ok := ecs.Get[Parent](world, cursor)
		if !ok {
			break
		}
		cursor = next.Entity
	}
	return ecs.Set(world, child, Parent{Entity: parent})
}

// ClearParent removes an entity's parent link.
func ClearParent(world *ecs.World, child ecs.Entity) bool { return ecs.Remove[Parent](world, child) }

// Children returns direct child entities in stable creation order.
func Children(world *ecs.World, parent ecs.Entity) []ecs.Entity {
	children := make([]ecs.Entity, 0)
	ecs.Each(world, func(entity ecs.Entity, relation Parent) {
		if relation.Entity == parent {
			children = append(children, entity)
		}
	})
	return children
}

// Propagate recalculates global transforms for every entity with a Transform.
// Invalid external parent links fail rather than silently producing transforms.
func Propagate(world *ecs.World) error {
	visiting := make(map[ecs.Entity]bool)
	resolved := make(map[ecs.Entity]GlobalTransform)
	var resolve func(ecs.Entity) (GlobalTransform, error)
	resolve = func(entity ecs.Entity) (GlobalTransform, error) {
		if global, ok := resolved[entity]; ok {
			return global, nil
		}
		if visiting[entity] {
			return GlobalTransform{}, fmt.Errorf("transform hierarchy contains a cycle at entity %d", entity)
		}
		local, ok := ecs.Get[Transform](world, entity)
		if !ok {
			return GlobalTransform{}, fmt.Errorf("entity %d has parent/child transform state but no Transform", entity)
		}
		visiting[entity] = true
		global := GlobalTransform{Position: local.Position, Rotation: local.Rotation, Scale: normalizedScale(local.Scale)}
		if relation, hasParent := ecs.Get[Parent](world, entity); hasParent {
			if !world.Alive(relation.Entity) {
				return GlobalTransform{}, fmt.Errorf("entity %d has dead parent %d", entity, relation.Entity)
			}
			parent, err := resolve(relation.Entity)
			if err != nil {
				return GlobalTransform{}, err
			}
			global = compose(parent, global)
		}
		delete(visiting, entity)
		resolved[entity] = global
		return global, nil
	}

	var propagateErr error
	ecs.Each(world, func(entity ecs.Entity, _ Transform) {
		if propagateErr != nil {
			return
		}
		global, err := resolve(entity)
		if err != nil {
			propagateErr = err
			return
		}
		propagateErr = ecs.Set(world, entity, global)
	})
	return propagateErr
}

func normalizedScale(value Vec2) Vec2 {
	if value.X == 0 && value.Y == 0 {
		return Vec2{X: 1, Y: 1}
	}
	return value
}

func compose(parent, child GlobalTransform) GlobalTransform {
	childPosition := Vec2{X: child.Position.X * parent.Scale.X, Y: child.Position.Y * parent.Scale.Y}
	cos, sin := math.Cos(parent.Rotation), math.Sin(parent.Rotation)
	rotated := Vec2{
		X: childPosition.X*cos - childPosition.Y*sin,
		Y: childPosition.X*sin + childPosition.Y*cos,
	}
	return GlobalTransform{
		Position: Vec2{X: parent.Position.X + rotated.X, Y: parent.Position.Y + rotated.Y},
		Rotation: parent.Rotation + child.Rotation,
		Scale:    Vec2{X: parent.Scale.X * child.Scale.X, Y: parent.Scale.Y * child.Scale.Y},
	}
}
