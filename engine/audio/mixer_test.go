package audio

import (
	"math"
	"testing"
)

type recordingBackend struct {
	started []Voice
	buses   map[Bus]BusState
}

func (b *recordingBackend) Start(voice Voice) error { b.started = append(b.started, voice); return nil }
func (b *recordingBackend) Stop(VoiceID) error      { return nil }
func (b *recordingBackend) SetVoice(Voice) error    { return nil }
func (b *recordingBackend) SetBus(bus Bus, state BusState) error {
	if b.buses == nil {
		b.buses = make(map[Bus]BusState)
	}
	b.buses[bus] = state
	return nil
}

func TestMixerTracksBusesAndVoices(t *testing.T) {
	backend := &recordingBackend{}
	mixer := NewMixer(backend)
	if err := mixer.CreateBus("effects"); err != nil {
		t.Fatal(err)
	}
	if err := mixer.SetBus("effects", BusState{Volume: .5}); err != nil {
		t.Fatal(err)
	}
	id, err := mixer.Play(Sound{Samples: []float32{0, .5}, SampleRate: 48_000, Channels: 1}, "effects", 1, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(backend.started) != 1 || !mixer.Stop(id) || len(mixer.Voices()) != 0 {
		t.Fatalf("voice lifecycle started=%d stopped=%t live=%d", len(backend.started), mixer.Stop(id), len(mixer.Voices()))
	}
}

type closingBackend struct {
	recordingBackend
	stopped []VoiceID
	closed  bool
}

func (b *closingBackend) Stop(id VoiceID) error {
	b.stopped = append(b.stopped, id)
	return nil
}

func (b *closingBackend) Close() error {
	b.closed = true
	return nil
}

func TestMixerCopiesSoundAndClosesAnOwnedBackend(t *testing.T) {
	backend := &closingBackend{}
	mixer := NewMixer(backend)
	sound := Sound{Samples: []float32{0, .5}, SampleRate: 48_000, Channels: 1}
	id, err := mixer.Play(sound, Master, 1, false)
	if err != nil {
		t.Fatal(err)
	}
	sound.Samples[1] = -1
	if got := mixer.Voices()[0].Sound.Samples[1]; got != .5 {
		t.Fatalf("stored sample = %g, want .5", got)
	}
	voices := mixer.Voices()
	voices[0].Sound.Samples[1] = -1
	if got := mixer.Voices()[0].Sound.Samples[1]; got != .5 {
		t.Fatalf("returned voice sample mutated mixer: %g", got)
	}
	if err := mixer.Close(); err != nil {
		t.Fatalf("close mixer: %v", err)
	}
	if !backend.closed || len(backend.stopped) != 1 || backend.stopped[0] != id || len(mixer.Voices()) != 0 {
		t.Fatalf("close backend=%t stopped=%v voices=%v", backend.closed, backend.stopped, mixer.Voices())
	}
}

func TestMixerRejectsInvalidPCMAndGains(t *testing.T) {
	if (Sound{Samples: []float32{float32(math.NaN())}, SampleRate: 48_000, Channels: 1}).Valid() {
		t.Fatal("NaN PCM validated")
	}
	if (Sound{Samples: []float32{1.1}, SampleRate: 48_000, Channels: 1}).Valid() {
		t.Fatal("out-of-range PCM validated")
	}
	mixer := NewMixer(nil)
	if _, err := mixer.Play(Sound{Samples: []float32{0}, SampleRate: 48_000, Channels: 1}, Master, math.NaN(), false); err == nil {
		t.Fatal("NaN voice gain succeeded")
	}
	if err := mixer.SetBus(Master, BusState{Volume: math.Inf(1)}); err == nil {
		t.Fatal("infinite bus gain succeeded")
	}
}
