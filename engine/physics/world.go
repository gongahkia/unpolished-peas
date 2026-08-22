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
// bodies collide only when each mask includes the other body's layer. Sensor
// bodies generate contacts but receive no positional or velocity response.
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

// ContactState identifies a pair's lifecycle transition during one Step.
type ContactState uint8

const (
	// ContactBegin reports a pair that was not overlapping during the prior step.
	ContactBegin ContactState = iota
	// ContactStay reports a pair that overlaps in consecutive steps.
	ContactStay
	// ContactEnd reports a pair that stopped overlapping after the prior step.
	ContactEnd
)

// Contact reports a pair's lifecycle transition. Normal points from First to
// Second for begin/stay contacts. End retains the final observed normal.
type Contact struct {
	First, Second BodyID
	Normal        Vec2
	Sensor        bool
	State         ContactState
}

// QueryHit is the first deterministic intersection reported by Raycast or
// SweepAABB. Fraction is measured along the supplied segment in [0, 1].
// Normal points away from the hit body and therefore opposes movement for a
// non-overlapping query.
type QueryHit struct {
	Body     BodyID
	Fraction float64
	Point    Vec2
	Normal   Vec2
}

// Config defines a World fixed-step cadence. Call StepFixed for the configured
// cadence; Step remains available for controlled simulations and tests that
// need an explicit duration.
type Config struct{ FixedDelta float64 }

// DefaultFixedDelta is the standard 60 Hz physics cadence.
const DefaultFixedDelta = 1.0 / 60.0

// World owns bodies and collision lifecycle events.
type World struct {
	next     BodyID
	bodies   map[BodyID]Body
	contacts []Contact
	previous map[contactKey]Contact
	fixed    float64
}

type contactKey struct{ first, second BodyID }

// NewWorld creates an empty 2D physics world with a 60 Hz fixed cadence.
func NewWorld() *World {
	world, err := NewWorldWithConfig(Config{FixedDelta: DefaultFixedDelta})
	if err != nil {
		panic(err)
	}
	return world
}

// NewWorldWithConfig creates an empty world with an explicit fixed cadence.
func NewWorldWithConfig(config Config) (*World, error) {
	if config.FixedDelta <= 0 || math.IsNaN(config.FixedDelta) || math.IsInf(config.FixedDelta, 0) {
		return nil, fmt.Errorf("physics fixed delta must be finite and positive")
	}
	return &World{
		next:     1,
		bodies:   make(map[BodyID]Body),
		previous: make(map[contactKey]Contact),
		fixed:    config.FixedDelta,
	}, nil
}

// FixedDelta returns the duration used by StepFixed.
func (w *World) FixedDelta() float64 { return w.fixed }

// StepFixed advances one configured fixed-duration simulation step.
func (w *World) StepFixed() error { return w.Step(w.fixed) }

// Add validates and inserts a body, returning its assigned ID.
func (w *World) Add(body Body) (BodyID, error) {
	if err := validBody(body); err != nil {
		return 0, err
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
	if err := validBody(body); err != nil {
		return fmt.Errorf("body %d: %w", body.ID, err)
	}
	w.bodies[body.ID] = body
	return nil
}

// Remove removes a body from the world. If it had an active contact, the next
// successful Step reports a ContactEnd for that pair.
func (w *World) Remove(id BodyID) bool {
	if _, ok := w.bodies[id]; !ok {
		return false
	}
	delete(w.bodies, id)
	return true
}

// Step advances bodies by dt seconds and resolves non-sensor AABB overlaps.
// Pair processing and Contacts output are stable by body ID. Callers that need
// reproducible simulation cadence should use StepFixed.
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
	current := make(map[contactKey]Contact)
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
			key := contactKey{first: firstID, second: secondID}
			state := ContactBegin
			if _, present := w.previous[key]; present {
				state = ContactStay
			}
			contact := Contact{First: firstID, Second: secondID, Normal: normal, Sensor: first.Sensor || second.Sensor, State: state}
			current[key] = contact
			if !contact.Sensor {
				w.resolve(firstID, secondID, normal, overlap)
			}
		}
	}
	contacts := make([]Contact, 0, len(current)+len(w.previous))
	for _, contact := range current {
		contacts = append(contacts, contact)
	}
	for key, previous := range w.previous {
		if _, present := current[key]; !present {
			previous.State = ContactEnd
			contacts = append(contacts, previous)
		}
	}
	sort.Slice(contacts, func(left, right int) bool {
		if contacts[left].First == contacts[right].First {
			return contacts[left].Second < contacts[right].Second
		}
		return contacts[left].First < contacts[right].First
	})
	w.contacts, w.previous = contacts, current
	return nil
}

// Contacts returns lifecycle events from the most recent Step in stable
// ID-pair order. It returns copies so callers cannot mutate World state.
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

// Overlap returns every body currently overlapping area and matching
// layerMask, in stable ID order. Invalid or empty queries return no IDs.
func (w *World) Overlap(area AABB, position Vec2, layerMask uint32) []BodyID {
	if layerMask == 0 || !finite(position) || !validAABB(area) {
		return nil
	}
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

// Raycast intersects the finite segment from origin to origin+delta with live
// body AABBs matching layerMask. exclude is ignored even when it matches the
// mask, allowing a body to cast from its own position. Invalid, zero-length,
// or empty queries return no hit. Equal-fraction hits use the lower body ID.
func (w *World) Raycast(origin, delta Vec2, layerMask uint32, exclude BodyID) (QueryHit, bool) {
	if layerMask == 0 || !finite(origin) || !finite(delta) || (delta.X == 0 && delta.Y == 0) {
		return QueryHit{}, false
	}
	return w.queryAABB(Vec2{}, origin, delta, layerMask, exclude)
}

// SweepAABB intersects an AABB centered at position while it travels by delta
// against live body AABBs matching layerMask. It is an immediate query: it
// does not move bodies, resolve contacts, or change contact lifecycle state.
// exclude is ignored even when it matches the mask.
func (w *World) SweepAABB(area AABB, position, delta Vec2, layerMask uint32, exclude BodyID) (QueryHit, bool) {
	if layerMask == 0 || !validAABB(area) || !finite(position) || !finite(delta) || (delta.X == 0 && delta.Y == 0) {
		return QueryHit{}, false
	}
	return w.queryAABB(area.HalfExtents, position, delta, layerMask, exclude)
}

func (w *World) queryAABB(extents, position, delta Vec2, layerMask uint32, exclude BodyID) (QueryHit, bool) {
	var best QueryHit
	found := false
	for _, id := range w.IDs() {
		if id == exclude {
			continue
		}
		body := w.bodies[id]
		if body.Layer&layerMask == 0 {
			continue
		}
		fraction, normal, ok := sweep(position, delta, extents, body)
		if !ok || (found && (fraction > best.Fraction || (fraction == best.Fraction && id > best.Body))) {
			continue
		}
		best = QueryHit{Body: id, Fraction: fraction, Point: position.add(delta.scale(fraction)), Normal: normal}
		found = true
	}
	return best, found
}

func sweep(position, delta, extents Vec2, target Body) (float64, Vec2, bool) {
	expanded := target.Shape.HalfExtents.add(extents)
	difference := position.sub(target.Position)
	overlapX, overlapY := expanded.X-math.Abs(difference.X), expanded.Y-math.Abs(difference.Y)
	if overlapX >= 0 && overlapY >= 0 {
		if overlapX < overlapY {
			if difference.X < 0 {
				return 0, Vec2{X: -1}, true
			}
			return 0, Vec2{X: 1}, true
		}
		if difference.Y < 0 {
			return 0, Vec2{Y: -1}, true
		}
		return 0, Vec2{Y: 1}, true
	}
	min := target.Position.sub(expanded)
	max := target.Position.add(expanded)
	xEntry, xExit, xNormal, ok := sweepAxis(position.X, delta.X, min.X, max.X, Vec2{X: -1}, Vec2{X: 1})
	if !ok {
		return 0, Vec2{}, false
	}
	yEntry, yExit, yNormal, ok := sweepAxis(position.Y, delta.Y, min.Y, max.Y, Vec2{Y: -1}, Vec2{Y: 1})
	if !ok {
		return 0, Vec2{}, false
	}
	entry, exit := math.Max(xEntry, yEntry), math.Min(xExit, yExit)
	if entry > exit || exit < 0 || entry > 1 {
		return 0, Vec2{}, false
	}
	normal := yNormal
	if xEntry > yEntry {
		normal = xNormal
	}
	if entry < 0 {
		entry = 0
	}
	return entry, normal, true
}

func sweepAxis(position, delta, minimum, maximum float64, negative, positive Vec2) (entry, exit float64, normal Vec2, ok bool) {
	if delta == 0 {
		if position < minimum || position > maximum {
			return 0, 0, Vec2{}, false
		}
		return math.Inf(-1), math.Inf(1), Vec2{}, true
	}
	if delta > 0 {
		return (minimum - position) / delta, (maximum - position) / delta, negative, true
	}
	return (maximum - position) / delta, (minimum - position) / delta, positive, true
}

func validBody(body Body) error {
	if body.Type != StaticBody && body.Type != DynamicBody && body.Type != KinematicBody {
		return fmt.Errorf("body type %d is invalid", body.Type)
	}
	if !validAABB(body.Shape) {
		return fmt.Errorf("body half extents must be finite and positive")
	}
	if !finite(body.Position) || !finite(body.Velocity) {
		return fmt.Errorf("body position and velocity must be finite")
	}
	if body.Layer == 0 {
		return fmt.Errorf("body collision layer must not be zero")
	}
	return nil
}

func validAABB(shape AABB) bool {
	return shape.HalfExtents.X > 0 && shape.HalfExtents.Y > 0 && finite(shape.HalfExtents)
}

func finite(value Vec2) bool {
	return !math.IsNaN(value.X) && !math.IsInf(value.X, 0) && !math.IsNaN(value.Y) && !math.IsInf(value.Y, 0)
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
