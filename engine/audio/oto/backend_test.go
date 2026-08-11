package oto

import (
	"encoding/binary"
	"errors"
	"math"
	"testing"

	"github.com/gongahkia/72/engine/audio"
)

func TestConvertResamplesAndExpandsMono(t *testing.T) {
	pcm, err := convert(audio.Sound{Samples: []float32{0, 1}, SampleRate: 2, Channels: 1}, 4, 2)
	if err != nil {
		t.Fatalf("convert: %v", err)
	}
	want := []float32{0, 0, .5, .5, 1, 1, 1, 1}
	if len(pcm) != len(want) {
		t.Fatalf("pcm length = %d, want %d", len(pcm), len(want))
	}
	for index := range want {
		if pcm[index] != want[index] {
			t.Fatalf("pcm[%d] = %g, want %g", index, pcm[index], want[index])
		}
	}
}

func TestConvertRejectsMoreThanStereo(t *testing.T) {
	_, err := convert(audio.Sound{Samples: []float32{0, 0, 0}, SampleRate: 48_000, Channels: 3}, 48_000, 2)
	if !errors.Is(err, ErrUnsupportedFormat) {
		t.Fatalf("convert error = %v, want unsupported format", err)
	}
}

func TestVoiceReaderAppliesLiveVoiceAndBusGain(t *testing.T) {
	backend := &Backend{
		channels: 2,
		buses: map[audio.Bus]audio.BusState{
			audio.Master: {Volume: .5},
			"effects":    {Volume: .5},
		},
		voices: map[audio.VoiceID]audio.Voice{
			1: {ID: 1, Bus: "effects", Volume: 1, Loop: true},
		},
	}
	reader := &voiceReader{backend: backend, id: 1, pcm: []float32{1, -1}}
	output := make([]byte, 8)
	if count, err := reader.Read(output); err != nil || count != len(output) {
		t.Fatalf("read = %d, %v", count, err)
	}
	if got := math.Float32frombits(binary.LittleEndian.Uint32(output[:4])); got != .25 {
		t.Fatalf("left sample = %g, want .25", got)
	}
	if got := math.Float32frombits(binary.LittleEndian.Uint32(output[4:])); got != -.25 {
		t.Fatalf("right sample = %g, want -.25", got)
	}
	backend.mu.Lock()
	backend.buses["effects"] = audio.BusState{Muted: true}
	backend.mu.Unlock()
	if count, err := reader.Read(output); err != nil || count != len(output) {
		t.Fatalf("muted read = %d, %v", count, err)
	}
	if got := math.Float32frombits(binary.LittleEndian.Uint32(output[:4])); got != 0 {
		t.Fatalf("muted sample = %g, want 0", got)
	}
}
