// Package audio provides backend-neutral playback and bus-mixing state.
package audio

import (
	"fmt"
	"sort"
)

// Sound is decoded PCM data. Samples are interleaved by channel and normalized
// to [-1, 1]. A decoder/driver owns format conversion at the boundary.
type Sound struct {
	Samples    []float32
	SampleRate int
	Channels   int
}

// Valid reports whether sound contains a usable PCM format.
func (s Sound) Valid() bool {
	return s.SampleRate > 0 && s.Channels > 0 && len(s.Samples)%s.Channels == 0
}

// Bus identifies a mix group. The Master bus always exists.
type Bus string

const Master Bus = "master"

// VoiceID identifies one requested sound playback.
type VoiceID uint64

// Voice describes a currently playing sound. Position is optional 2D spatial
// metadata that backends may use for panning and attenuation.
type Voice struct {
	ID       VoiceID
	Sound    Sound
	Bus      Bus
	Volume   float64
	Loop     bool
	Position Vec2
	Spatial  bool
}

// Vec2 is a 2D audio position.
type Vec2 struct{ X, Y float64 }

// Backend receives playback state changes. It is intentionally narrow so the
// engine does not leak a platform audio dependency into games.
type Backend interface {
	Start(Voice) error
	Stop(VoiceID) error
	SetVoice(Voice) error
	SetBus(Bus, BusState) error
}

// BusState controls a mix group.
type BusState struct {
	Volume float64
	Muted  bool
}

// Mixer manages voices and buses, delegating actual output to Backend.
type Mixer struct {
	backend Backend
	nextID  VoiceID
	buses   map[Bus]BusState
	voices  map[VoiceID]Voice
}

// NewMixer creates a mixer. backend can be nil for deterministic/headless use.
func NewMixer(backend Backend) *Mixer {
	return &Mixer{
		backend: backend,
		buses:   map[Bus]BusState{Master: {Volume: 1}},
		voices:  make(map[VoiceID]Voice),
	}
}

// CreateBus adds a named bus inheriting neutral gain.
func (m *Mixer) CreateBus(bus Bus) error {
	if bus == "" {
		return fmt.Errorf("audio bus must not be empty")
	}
	if _, exists := m.buses[bus]; exists {
		return fmt.Errorf("audio bus %q already exists", bus)
	}
	m.buses[bus] = BusState{Volume: 1}
	return m.applyBus(bus)
}

// SetBus updates gain/mute state for a bus.
func (m *Mixer) SetBus(bus Bus, state BusState) error {
	if state.Volume < 0 {
		return fmt.Errorf("audio bus %q has negative volume %g", bus, state.Volume)
	}
	if _, exists := m.buses[bus]; !exists {
		return fmt.Errorf("audio bus %q does not exist", bus)
	}
	m.buses[bus] = state
	return m.applyBus(bus)
}

// BusState returns a bus's current mix state.
func (m *Mixer) BusState(bus Bus) (BusState, bool) { state, ok := m.buses[bus]; return state, ok }

// Play starts a voice and returns its stable ID.
func (m *Mixer) Play(sound Sound, bus Bus, volume float64, loop bool) (VoiceID, error) {
	if !sound.Valid() {
		return 0, fmt.Errorf("sound must have interleaved samples, channels, and sample rate")
	}
	if volume < 0 {
		return 0, fmt.Errorf("voice volume must not be negative")
	}
	if _, exists := m.buses[bus]; !exists {
		return 0, fmt.Errorf("audio bus %q does not exist", bus)
	}
	m.nextID++
	voice := Voice{ID: m.nextID, Sound: sound, Bus: bus, Volume: volume, Loop: loop}
	if m.backend != nil {
		if err := m.backend.Start(voice); err != nil {
			return 0, fmt.Errorf("start voice: %w", err)
		}
	}
	m.voices[voice.ID] = voice
	return voice.ID, nil
}

// SetVoice updates a live voice. Sound and bus are immutable after Play.
func (m *Mixer) SetVoice(id VoiceID, volume float64, position Vec2, spatial bool) error {
	if volume < 0 {
		return fmt.Errorf("voice volume must not be negative")
	}
	voice, ok := m.voices[id]
	if !ok {
		return fmt.Errorf("voice %d does not exist", id)
	}
	voice.Volume, voice.Position, voice.Spatial = volume, position, spatial
	if m.backend != nil {
		if err := m.backend.SetVoice(voice); err != nil {
			return fmt.Errorf("set voice %d: %w", id, err)
		}
	}
	m.voices[id] = voice
	return nil
}

// Stop stops and removes a live voice.
func (m *Mixer) Stop(id VoiceID) bool {
	if _, ok := m.voices[id]; !ok {
		return false
	}
	if m.backend != nil {
		if err := m.backend.Stop(id); err != nil {
			return false
		}
	}
	delete(m.voices, id)
	return true
}

// Voices returns active voices ordered by playback ID.
func (m *Mixer) Voices() []Voice {
	voices := make([]Voice, 0, len(m.voices))
	for _, voice := range m.voices {
		voices = append(voices, voice)
	}
	sort.Slice(voices, func(left, right int) bool { return voices[left].ID < voices[right].ID })
	return voices
}

func (m *Mixer) applyBus(bus Bus) error {
	if m.backend == nil {
		return nil
	}
	if err := m.backend.SetBus(bus, m.buses[bus]); err != nil {
		return fmt.Errorf("set audio bus %q: %w", bus, err)
	}
	return nil
}
