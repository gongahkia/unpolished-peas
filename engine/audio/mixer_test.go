package audio

import "testing"

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
