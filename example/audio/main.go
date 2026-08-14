// Command audio demonstrates output-device playback through the public mixer.
package main

import (
	"fmt"
	"math"
	"time"

	"github.com/gongahkia/72/engine/audio"
	"github.com/gongahkia/72/engine/audio/oto"
)

func main() {
	setAudioStatus("waiting for a key, click, or touch to enable audio")
	backend, err := oto.New(48_000, 2)
	if err != nil {
		setAudioStatus("audio initialization failed")
		panic(fmt.Errorf("open audio output: %w", err))
	}
	setAudioStatus("audio context ready")
	mixer := audio.NewMixer(backend)
	defer func() {
		if err := mixer.Close(); err != nil {
			fmt.Printf("close audio: %v\n", err)
		}
	}()
	if err := mixer.CreateBus("effects"); err != nil {
		panic(err)
	}
	if err := mixer.SetBus("effects", audio.BusState{Volume: .5}); err != nil {
		panic(err)
	}
	voice, err := mixer.Play(tone(48_000, 440, 250*time.Millisecond), "effects", .25, true)
	if err != nil {
		panic(fmt.Errorf("play tone: %w", err))
	}
	setAudioStatus("playing 440 Hz at 25% gain")
	fmt.Println("playing 440 Hz tone at 25% voice gain")
	time.Sleep(300 * time.Millisecond)
	if err := mixer.SetVoice(voice, .5, audio.Vec2{}, false); err != nil {
		panic(fmt.Errorf("adjust tone: %w", err))
	}
	setAudioStatus("playing 440 Hz at 50% gain")
	fmt.Println("adjusted tone to 50% voice gain")
	time.Sleep(300 * time.Millisecond)
	if mixer.Stop(voice) {
		setAudioStatus("stopped")
		fmt.Println("stopped tone")
	}
}

func tone(sampleRate int, frequency float64, duration time.Duration) audio.Sound {
	frames := int(float64(sampleRate) * duration.Seconds())
	samples := make([]float32, frames)
	for frame := range samples {
		samples[frame] = float32(math.Sin(2 * math.Pi * frequency * float64(frame) / float64(sampleRate)))
	}
	return audio.Sound{Samples: samples, SampleRate: sampleRate, Channels: 1}
}
