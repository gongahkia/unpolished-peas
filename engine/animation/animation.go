// Package animation provides deterministic, duration-driven sprite-sheet
// playback. It deliberately contains no renderer, asset, or animation-graph
// ownership; games apply a player's source rectangle to their own sprite draw.
package animation

import (
	"fmt"
	"math"
	"time"

	"github.com/gongahkia/72/engine"
)

// Playback controls what happens after the last clip frame has displayed.
type Playback uint8

const (
	// Loop restarts at the first frame after the last frame.
	Loop Playback = iota
	// Once holds the last frame after its duration has elapsed.
	Once
	// PingPong reverses direction at each endpoint without repeating it.
	PingPong
)

// Frame is one sprite-sheet source rectangle and its display duration. Event
// is emitted when playback enters this frame; an empty Event emits nothing.
type Frame struct {
	Source   engine.Rect
	Duration time.Duration
	Event    string
}

// Clip is an immutable validated sequence of animation frames.
type Clip struct {
	frames   []Frame
	playback Playback
}

// NewClip validates and copies frames so subsequent caller mutation cannot
// change playback. Source coordinates use the same logical pixel convention
// as engine.Rect and can be copied into a renderer sprite source rectangle.
func NewClip(frames []Frame, playback Playback) (Clip, error) {
	if len(frames) == 0 {
		return Clip{}, fmt.Errorf("animation clip requires at least one frame")
	}
	if playback != Loop && playback != Once && playback != PingPong {
		return Clip{}, fmt.Errorf("animation clip has unsupported playback %d", playback)
	}
	result := Clip{frames: append([]Frame(nil), frames...), playback: playback}
	for index, frame := range result.frames {
		if !finiteRect(frame.Source) || frame.Source.X < 0 || frame.Source.Y < 0 || frame.Source.W <= 0 || frame.Source.H <= 0 {
			return Clip{}, fmt.Errorf("animation frame %d source must be finite, non-negative, and positive-sized", index)
		}
		if frame.Duration <= 0 {
			return Clip{}, fmt.Errorf("animation frame %d duration must be positive", index)
		}
	}
	return result, nil
}

// Frames returns a copy of this clip's frame data in playback order.
func (c Clip) Frames() []Frame { return append([]Frame(nil), c.frames...) }

// Playback returns this clip's terminal playback policy.
func (c Clip) Playback() Playback { return c.playback }

// Event reports one stable frame-entry event emitted by Player.Advance.
type Event struct {
	Frame int
	Name  string
}

// Player tracks one independent playhead through an immutable Clip. Its zero
// value has no clip; construct it with NewPlayer.
type Player struct {
	clip      Clip
	frame     int
	direction int
	elapsed   time.Duration
	finished  bool
}

// NewPlayer creates a player at the first frame. Construction does not emit a
// frame event; events are emitted only when Advance enters a subsequent frame.
func NewPlayer(clip Clip) (*Player, error) {
	if len(clip.frames) == 0 {
		return nil, fmt.Errorf("animation player requires a non-empty clip")
	}
	if clip.playback != Loop && clip.playback != Once && clip.playback != PingPong {
		return nil, fmt.Errorf("animation player has unsupported playback %d", clip.playback)
	}
	return &Player{clip: clip, direction: 1}, nil
}

// Source returns the current frame's sprite-sheet source rectangle.
func (p *Player) Source() engine.Rect {
	if p == nil || len(p.clip.frames) == 0 {
		return engine.Rect{}
	}
	return p.clip.frames[p.frame].Source
}

// Frame returns the zero-based current frame index, or -1 for a nil or
// uninitialized player.
func (p *Player) Frame() int {
	if p == nil || len(p.clip.frames) == 0 {
		return -1
	}
	return p.frame
}

// Finished reports whether a Once player has consumed its final frame.
func (p *Player) Finished() bool { return p != nil && p.finished }

// Restart returns playback to the first frame without emitting an event.
func (p *Player) Restart() {
	if p == nil {
		return
	}
	p.frame, p.direction, p.elapsed, p.finished = 0, 1, 0, false
}

// Advance moves the playhead by delta and returns named frame-entry events in
// chronological order. A negative delta is invalid. A sufficiently large
// delta intentionally reports every crossed event rather than coalescing it.
func (p *Player) Advance(delta time.Duration) ([]Event, error) {
	if p == nil || len(p.clip.frames) == 0 {
		return nil, fmt.Errorf("advance animation player: player is not initialized")
	}
	if delta < 0 {
		return nil, fmt.Errorf("advance animation player: delta must not be negative")
	}
	if delta == 0 || p.finished {
		return nil, nil
	}
	events := make([]Event, 0)
	for delta > 0 && !p.finished {
		remaining := p.clip.frames[p.frame].Duration - p.elapsed
		if delta < remaining {
			p.elapsed += delta
			break
		}
		delta -= remaining
		p.elapsed = 0
		if !p.enterNext(&events) {
			break
		}
	}
	return events, nil
}

func (p *Player) enterNext(events *[]Event) bool {
	switch p.clip.playback {
	case Loop:
		p.frame = (p.frame + 1) % len(p.clip.frames)
	case Once:
		if p.frame == len(p.clip.frames)-1 {
			p.finished = true
			return false
		}
		p.frame++
	case PingPong:
		if len(p.clip.frames) == 1 {
			p.frame = 0
		} else if p.direction > 0 && p.frame == len(p.clip.frames)-1 {
			p.direction = -1
			p.frame--
		} else if p.direction < 0 && p.frame == 0 {
			p.direction = 1
			p.frame++
		} else {
			p.frame += p.direction
		}
	default:
		p.finished = true
		return false
	}
	if name := p.clip.frames[p.frame].Event; name != "" {
		*events = append(*events, Event{Frame: p.frame, Name: name})
	}
	return true
}

func finiteRect(value engine.Rect) bool {
	return finite(value.X) && finite(value.Y) && finite(value.W) && finite(value.H)
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }
