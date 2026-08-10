// Package physics provides deterministic axis-aligned 2D collision and rigid
// body integration suitable for gameplay systems. It intentionally leaves
// advanced shape support to a future backend or extension.
package physics

import (
	"fmt"
	"math"
	"sort"
)

// BodyID identifies a body in a World.
type BodyID uint64

// BodyType controls whether a body receives velocity integration and collision
// response.
type BodyType uint8

const (
	StaticBody BodyType = iota
	DynamicBody
	KinematicBody
)

// Vec2 is a two-dimensional vector.
type Vec2 struct{ X, Y float64 }

func (v Vec2) add(other Vec2) Vec2      { return Vec2{X: v.X + other.X, Y: v.Y + other.Y} }
func (v Vec2) sub(other Vec2) Vec2      { return Vec2{X: v.X - other.X, Y: v.Y - other.Y} }
func (v Vec2) scale(value float64) Vec2 { return Vec2{X: v.X * value, Y: v.Y * value} }

// AABB is an axis-aligned collision shape centered at Position.
type AABB struct{ HalfExtents Vec2 }

// Body is an AABB body. Layer and Mask use the usual category/mask rule: two
// bodies collide only when each mask includes the other body's layer.
type Body struct {
	ID       BodyID
	Type     BodyType
	Position Vec2
	Velocity Vec2
	Shape    AABB
	Layer    uint32
	Mask     uint32
	Sensor   bool
}

// Contact reports a pair that overlapped during the most recent Step.
type Contact struct {
	First, Second BodyID
	Normal        Vec2
	Sensor        bool
}

// World owns bodies and collision events.
type World struct {
	next     BodyID
	bodies   map[BodyID]Body
	contacts []Contact
}

// NewWorld creates an empty 2D physics world.
func NewWorld() *World { return &World{next: 1, bodies: make(map[BodyID]Body)} }

// Add validates and inserts a body, returning its assigned ID.
func (w *World) Add(body Body) (BodyID, error) {
	if body.Shape.HalfExtents.X <= 0 || body.Shape.HalfExtents.Y <= 0 {
		return 0, fmt.Errorf("body half extents must be positive")
	}
	if body.Layer == 0 {
		return 0, fmt.Errorf("body collision layer must not be zero")
	}
	w.next++
	body.ID = w.next - 1
	w.bodies[body.ID] = body
	return body.ID, nil
}

// Get returns a copy of a body.
func (w *World) Get(id BodyID) (Body, bool) { body, ok := w.bodies[id]; return body, ok }

// Set replaces a live body's state while retaining its identity.
func (w *World) Set(body Body) error {
	if _, ok := w.bodies[body.ID]; !ok {
		return fmt.Errorf("body %d does not exist", body.ID)
	}
	if body.Shape.HalfExtents.X <= 0 || body.Shape.HalfExtents.Y <= 0 || body.Layer == 0 {
		return fmt.Errorf("body %d has invalid shape or collision layer", body.ID)
	}
	w.bodies[body.ID] = body
	return nil
}

// Remove removes a body from the world.
func (w *World) Remove(id BodyID) bool {
	if _, ok := w.bodies[id]; !ok {
		return false
	}
	delete(w.bodies, id)
	return true
}

// Step advances bodies by dt seconds and resolves non-sensor AABB overlaps.
// Pair processing is stable by body ID, which makes equal input deterministic.
func (w *World) Step(dt float64) error {
	if dt < 0 || math.IsNaN(dt) || math.IsInf(dt, 0) {
		return fmt.Errorf("physics step duration must be finite and non-negative")
	}
	ids := w.IDs()
	for _, id := range ids {
		body := w.bodies[id]
		if body.Type == DynamicBody || body.Type == KinematicBody {
			body.Position = body.Position.add(body.Velocity.scale(dt))
			w.bodies[id] = body
		}
	}
	w.contacts = w.contacts[:0]
	for firstIndex, firstID := range ids {
		for _, secondID := range ids[firstIndex+1:] {
			first, second := w.bodies[firstID], w.bodies[secondID]
			if !shouldCollide(first, second) {
				continue
			}
			normal, overlap, ok := collision(first, second)
			if !ok {
				continue
			}
			contact := Contact{First: firstID, Second: secondID, Normal: normal, Sensor: first.Sensor || second.Sensor}
			w.contacts = append(w.contacts, contact)
			if !contact.Sensor {
				w.resolve(firstID, secondID, normal, overlap)
			}
		}
	}
	return nil
}

// Contacts returns contacts from the most recent Step in stable ID-pair order.
func (w *World) Contacts() []Contact { return append([]Contact(nil), w.contacts...) }

// IDs returns live body IDs in stable creation order.
func (w *World) IDs() []BodyID {
	ids := make([]BodyID, 0, len(w.bodies))
	for id := range w.bodies {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(left, right int) bool { return ids[left] < ids[right] })
	return ids
}

// Overlap returns every body currently overlapping area and matching layerMask.
func (w *World) Overlap(area AABB, position Vec2, layerMask uint32) []BodyID {
	result := make([]BodyID, 0)
	query := Body{Position: position, Shape: area, Layer: layerMask, Mask: ^uint32(0)}
	for _, id := range w.IDs() {
		body := w.bodies[id]
		if body.Layer&layerMask == 0 {
			continue
		}
		if _, _, ok := collision(query, body); ok {
			result = append(result, id)
		}
	}
	return result
}

func shouldCollide(first, second Body) bool {
	return first.Mask&second.Layer != 0 && second.Mask&first.Layer != 0 && (first.Type != StaticBody || second.Type != StaticBody)
}

func collision(first, second Body) (Vec2, float64, bool) {
	delta := second.Position.sub(first.Position)
	overlapX := first.Shape.HalfExtents.X + second.Shape.HalfExtents.X - math.Abs(delta.X)
	overlapY := first.Shape.HalfExtents.Y + second.Shape.HalfExtents.Y - math.Abs(delta.Y)
	if overlapX <= 0 || overlapY <= 0 {
		return Vec2{}, 0, false
	}
	if overlapX < overlapY {
		if delta.X < 0 {
			return Vec2{X: -1}, overlapX, true
		}
		return Vec2{X: 1}, overlapX, true
	}
	if delta.Y < 0 {
		return Vec2{Y: -1}, overlapY, true
	}
	return Vec2{Y: 1}, overlapY, true
}

func (w *World) resolve(firstID, secondID BodyID, normal Vec2, overlap float64) {
	first, second := w.bodies[firstID], w.bodies[secondID]
	dynamicFirst, dynamicSecond := first.Type == DynamicBody, second.Type == DynamicBody
	if !dynamicFirst && !dynamicSecond {
		return
	}
	move := normal.scale(overlap)
	switch {
	case dynamicFirst && dynamicSecond:
		first.Position = first.Position.sub(move.scale(.5))
		second.Position = second.Position.add(move.scale(.5))
		if normal.X != 0 {
			first.Velocity.X, second.Velocity.X = 0, 0
		} else {
			first.Velocity.Y, second.Velocity.Y = 0, 0
		}
	case dynamicFirst:
		first.Position = first.Position.sub(move)
		if normal.X != 0 {
			first.Velocity.X = 0
		} else {
			first.Velocity.Y = 0
		}
	case dynamicSecond:
		second.Position = second.Position.add(move)
		if normal.X != 0 {
			second.Velocity.X = 0
		} else {
			second.Velocity.Y = 0
		}
	}
	w.bodies[firstID], w.bodies[secondID] = first, second
}
