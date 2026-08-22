// Package oto provides an output-device backend for engine/audio using Oto.
// The package is deliberately separate from engine/audio so headless games and
// tests do not create an operating-system audio device.
package oto

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"sync"

	"github.com/ebitengine/oto/v3"
	"github.com/gongahkia/72/engine/audio"
)

var (
	// ErrClosed reports an operation attempted after Backend.Close.
	ErrClosed = errors.New("audio output backend is closed")
	// ErrDeviceUnavailable reports a context or player device failure.
	ErrDeviceUnavailable = errors.New("audio output device is unavailable")
	// ErrUnsupportedFormat reports PCM that this output adapter cannot mix.
	ErrUnsupportedFormat = errors.New("unsupported audio output format")
)

// Backend owns one Oto output context. Its stream format is fixed for its
// lifetime; New supports mono or stereo float32 output. Source sounds are
// resampled to the stream rate and may be mono or stereo.
type Backend struct {
	mu         sync.RWMutex
	context    *oto.Context
	sampleRate int
	channels   int
	buses      map[audio.Bus]audio.BusState
	voices     map[audio.VoiceID]audio.Voice
	players    map[audio.VoiceID]*oto.Player
	closed     bool
}

// New creates and waits for the process-wide Oto output context. Oto permits
// only one context in a process; callers should create one Backend and share it
// with one or more mixers. Sample rate must match the desired output device
// stream, normally 48 kHz or 44.1 kHz.
func New(sampleRate, channels int) (*Backend, error) {
	if sampleRate <= 0 {
		return nil, fmt.Errorf("audio sample rate must be positive")
	}
	if channels != 1 && channels != 2 {
		return nil, fmt.Errorf("%w: output channels must be mono or stereo, got %d", ErrUnsupportedFormat, channels)
	}
	context, ready, err := oto.NewContext(&oto.NewContextOptions{
		SampleRate:   sampleRate,
		ChannelCount: channels,
		Format:       oto.FormatFloat32LE,
	})
	if err != nil {
		return nil, fmt.Errorf("create audio output context: %w", err)
	}
	<-ready
	if err := context.Err(); err != nil {
		return nil, deviceError("initialize", err)
	}
	return &Backend{
		context:    context,
		sampleRate: sampleRate,
		channels:   channels,
		buses:      map[audio.Bus]audio.BusState{audio.Master: {Volume: 1}},
		voices:     make(map[audio.VoiceID]audio.Voice),
		players:    make(map[audio.VoiceID]*oto.Player),
	}, nil
}

// Start creates an independent Oto player for voice and begins asynchronous
// playback. The source is converted to the fixed stream format before the
// player starts, so callers can safely reuse or discard their input slice.
func (b *Backend) Start(voice audio.Voice) error {
	pcm, err := convert(voice.Sound, b.sampleRate, b.channels)
	if err != nil {
		return err
	}
	b.mu.Lock()
	if err := b.availableLocked("start"); err != nil {
		b.mu.Unlock()
		return err
	}
	if _, exists := b.voices[voice.ID]; exists {
		b.mu.Unlock()
		return fmt.Errorf("audio voice %d already exists", voice.ID)
	}
	b.voices[voice.ID] = cloneVoice(voice)
	b.mu.Unlock()
	player := b.context.NewPlayer(&voiceReader{backend: b, id: voice.ID, pcm: pcm})
	if err := player.Err(); err != nil {
		b.mu.Lock()
		delete(b.voices, voice.ID)
		b.mu.Unlock()
		return deviceError("create player", err)
	}
	b.mu.Lock()
	if err := b.availableLocked("start"); err != nil {
		b.mu.Unlock()
		player.Pause()
		return err
	}
	if _, exists := b.voices[voice.ID]; !exists {
		b.mu.Unlock()
		player.Pause()
		return fmt.Errorf("audio voice %d was stopped before playback started", voice.ID)
	}
	b.players[voice.ID] = player
	b.mu.Unlock()
	player.Play()
	return nil
}

// Stop pauses and releases backend ownership of a voice. Oto retains no
// player-device resource that needs explicit Close after v3.4.
func (b *Backend) Stop(id audio.VoiceID) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.availableLocked("stop"); err != nil {
		return err
	}
	player, exists := b.players[id]
	if !exists {
		return nil
	}
	player.Pause()
	delete(b.players, id)
	delete(b.voices, id)
	return nil
}

// SetVoice updates live gain and optional spatial metadata. This adapter does
// not spatialize, but preserves the metadata for a future spatial backend.
func (b *Backend) SetVoice(voice audio.Voice) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.availableLocked("set voice"); err != nil {
		return err
	}
	if _, exists := b.players[voice.ID]; !exists {
		return fmt.Errorf("audio voice %d does not exist", voice.ID)
	}
	b.voices[voice.ID] = cloneVoice(voice)
	return nil
}

// SetBus updates the gain/mute state used by every current and future voice on
// bus. Master is multiplied with the voice's selected bus.
func (b *Backend) SetBus(bus audio.Bus, state audio.BusState) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.availableLocked("set bus"); err != nil {
		return err
	}
	b.buses[bus] = state
	return nil
}

// Err reports the current output-device or player error. It is safe to call
// from diagnostics without changing playback state.
func (b *Backend) Err() error {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.closed {
		return ErrClosed
	}
	if err := b.context.Err(); err != nil {
		return deviceError("context", err)
	}
	for id, player := range b.players {
		if err := player.Err(); err != nil {
			return fmt.Errorf("%w: player for voice %d: %v", ErrDeviceUnavailable, id, err)
		}
	}
	return nil
}

// Close pauses all players and suspends the output context. Oto contexts are
// process-wide and do not expose a destructive Close operation, so another Oto
// context cannot be created after this call in the same process.
func (b *Backend) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil
	}
	for _, player := range b.players {
		player.Pause()
	}
	b.players = make(map[audio.VoiceID]*oto.Player)
	b.voices = make(map[audio.VoiceID]audio.Voice)
	b.closed = true
	if err := b.context.Suspend(); err != nil {
		return deviceError("suspend", err)
	}
	return nil
}

func (b *Backend) availableLocked(operation string) error {
	if b.closed {
		return fmt.Errorf("%s: %w", operation, ErrClosed)
	}
	if err := b.context.Err(); err != nil {
		return deviceError(operation, err)
	}
	for id, player := range b.players {
		if err := player.Err(); err != nil {
			return fmt.Errorf("%w during %s for voice %d: %v", ErrDeviceUnavailable, operation, id, err)
		}
	}
	return nil
}

type voiceReader struct {
	backend *Backend
	id      audio.VoiceID
	pcm     []float32
	frame   int
}

func (r *voiceReader) Read(output []byte) (int, error) {
	channels := r.backend.channels
	bytesPerFrame := channels * 4
	frames := len(output) / bytesPerFrame
	if frames == 0 {
		return 0, nil
	}
	r.backend.mu.RLock()
	voice, active := r.backend.voices[r.id]
	bus := r.backend.buses[voice.Bus]
	master := r.backend.buses[audio.Master]
	r.backend.mu.RUnlock()
	if !active {
		return 0, io.EOF
	}
	gain := voice.Volume * appliedGain(bus) * appliedGain(master)
	written := 0
	available := len(r.pcm) / channels
	for index := 0; index < frames; index++ {
		if r.frame == available {
			if !voice.Loop {
				if written == 0 {
					return 0, io.EOF
				}
				return written, io.EOF
			}
			r.frame = 0
		}
		for channel := 0; channel < channels; channel++ {
			sample := clamp(r.pcm[r.frame*channels+channel] * float32(gain))
			binary.LittleEndian.PutUint32(output[written:], math.Float32bits(sample))
			written += 4
		}
		r.frame++
	}
	return written, nil
}

func convert(sound audio.Sound, outputRate, outputChannels int) ([]float32, error) {
	if !sound.Valid() {
		return nil, fmt.Errorf("%w: invalid PCM source", ErrUnsupportedFormat)
	}
	if sound.Channels != 1 && sound.Channels != 2 {
		return nil, fmt.Errorf("%w: source channels must be mono or stereo, got %d", ErrUnsupportedFormat, sound.Channels)
	}
	frames := len(sound.Samples) / sound.Channels
	outputFrames := int(math.Ceil(float64(frames) * float64(outputRate) / float64(sound.SampleRate)))
	if outputFrames <= 0 {
		return nil, fmt.Errorf("%w: source contains no frames", ErrUnsupportedFormat)
	}
	pcm := make([]float32, outputFrames*outputChannels)
	for frame := 0; frame < outputFrames; frame++ {
		position := float64(frame) * float64(sound.SampleRate) / float64(outputRate)
		left := min(int(position), frames-1)
		right := min(left+1, frames-1)
		mix := float32(position - float64(left))
		for channel := 0; channel < outputChannels; channel++ {
			pcm[frame*outputChannels+channel] = interpolatedSample(sound, left, right, channel, mix)
		}
	}
	return pcm, nil
}

func interpolatedSample(sound audio.Sound, left, right, outputChannel int, mix float32) float32 {
	channel := outputChannel
	if sound.Channels == 1 {
		channel = 0
	} else if outputChannel >= sound.Channels {
		channel = sound.Channels - 1
	}
	start := sound.Samples[left*sound.Channels+channel]
	end := sound.Samples[right*sound.Channels+channel]
	return start + (end-start)*mix
}

func appliedGain(state audio.BusState) float64 {
	if state.Muted {
		return 0
	}
	return state.Volume
}

func clamp(value float32) float32 {
	return min(1, max(-1, value))
}

func cloneVoice(voice audio.Voice) audio.Voice {
	voice.Sound.Samples = append([]float32(nil), voice.Sound.Samples...)
	return voice
}

func deviceError(operation string, err error) error {
	return fmt.Errorf("%w during %s: %v", ErrDeviceUnavailable, operation, err)
}
