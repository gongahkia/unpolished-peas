// Package sim owns deterministic, renderer-independent game state.
package sim

import "math"

const (
	TickRate   = 60
	ViewportW  = 640
	ViewportH  = 360
	RoomW      = 640.0
	RoomCount  = 10
	ArenaW     = RoomW * RoomCount
	ArenaH     = 720.0
	TileSize   = 16.0
	Gravity    = 0.58
	JumpSpeed  = 10.2
	MaxJumpRun = 128.0
)

// Vec is a simulation-space vector measured in logical pixels.
type Vec struct {
	X, Y float64
}

func (v Vec) Add(other Vec) Vec          { return Vec{v.X + other.X, v.Y + other.Y} }
func (v Vec) Sub(other Vec) Vec          { return Vec{v.X - other.X, v.Y - other.Y} }
func (v Vec) Scale(s float64) Vec        { return Vec{v.X * s, v.Y * s} }
func (v Vec) Dot(other Vec) float64      { return v.X*other.X + v.Y*other.Y }
func (v Vec) LengthSq() float64          { return v.Dot(v) }
func (v Vec) Length() float64            { return math.Sqrt(v.LengthSq()) }
func (v Vec) Distance(other Vec) float64 { return v.Sub(other).Length() }

func (v Vec) Normalized() Vec {
	length := v.Length()
	if length == 0 {
		return Vec{}
	}
	return v.Scale(1 / length)
}

func clamp(value, low, high float64) float64 {
	return math.Max(low, math.Min(value, high))
}

func clampArena(position Vec, radius float64) Vec {
	return Vec{
		X: clamp(position.X, radius, ArenaW-radius),
		Y: clamp(position.Y, radius, ArenaH-radius),
	}
}

func nearestPointOnSegment(point, start, end Vec) Vec {
	delta := end.Sub(start)
	denom := delta.LengthSq()
	if denom == 0 {
		return start
	}
	t := clamp(point.Sub(start).Dot(delta)/denom, 0, 1)
	return start.Add(delta.Scale(t))
}
