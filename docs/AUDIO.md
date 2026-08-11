# audio playback

`engine/audio` owns portable playback state: `Mixer`, buses, voices, volume,
and loop policy. `engine/audio/oto` is the optional output-device adapter. A
game uses only the `audio` package in its own API; it creates the Oto backend at
its composition boundary and passes it to one mixer.

```go
backend, err := oto.New(48_000, 2)
if err != nil {
    return err
}
mixer := audio.NewMixer(backend)
defer mixer.Close()

sound, err := assets.DecodeWAV("audio/jump.wav", file)
if err != nil {
    return err
}
id, err := mixer.Play(sound.Audio(), audio.Master, .8, false)
// mixer.SetVoice(id, .5, audio.Vec2{}, false) adjusts the live voice.
// mixer.Stop(id) stops it immediately.
```

[`example/audio`](../example/audio) is a runnable sine-wave sample. It opens a
48 kHz stereo device, starts a looping tone, changes its voice gain, stops it,
and closes the mixer:

```sh
go run ./example/audio
```

## formats and mixing

`assets.DecodeWAV` is the supported decoder path. It accepts uncompressed PCM
8/16/24/32-bit and IEEE float32 WAV, returning normalized interleaved samples.
The Oto adapter accepts decoded mono or stereo source sound, linearly resamples
it to its fixed output rate, and expands mono into both stereo channels. It
rejects wider channel layouts with `oto.ErrUnsupportedFormat`; surround mixing,
compressed audio, streaming files, and 3D spatialization are intentionally not
part of this milestone.

The output context has one immutable sample rate and one or two output channels.
Voice gain is multiplied by its bus and the master bus for every PCM read;
changing a voice or bus therefore applies to live playback. Gains are finite
and non-negative. Values above one can clip the float32 output, so applications
should normally use `[0, 1]` gain.

`Mixer.Play` and `Mixer.Voices` copy sound sample slices. A caller can safely
reuse or mutate its original decoded value without changing an active voice.

## device ownership and failure policy

Oto permits one process-wide output context. Create one `oto.Backend`, share it
where needed, and call `Mixer.Close` when playback is permanently finished.
Closing pauses players and suspends the context; Oto does not provide a
destructive context close or permit creating a replacement context in the same
process.

If initialization fails, `oto.New` returns a contextual error. After a device
or player failure, `Backend.Err` and subsequent backend operations return an
error that wraps `oto.ErrDeviceUnavailable`. Treat it as terminal for this
process: stop gameplay audio, report the error through the application’s
diagnostics/UI, and do not attempt to recreate another Oto context. A missing
or unsupported decoded format returns `oto.ErrUnsupportedFormat` before a
voice starts. Headless/test callers can use `audio.NewMixer(nil)` or a fake
`audio.Backend` and retain deterministic mixer state without an audio device.

On Linux, Oto requires ALSA development/runtime support. On macOS it uses
AudioToolbox; on Windows it needs no CGO. Oto documents WebAssembly support,
but this repository has not independently verified audible browser output, so
it is not an audio support claim for the future browser host.

## verification

`engine/audio` tests bus/voice state, copies, lifecycle forwarding, invalid
gain/PCM rejection, and fake backend behavior. `engine/audio/oto` tests source
format rejection, deterministic resampling/channel expansion, and live
bus/voice gain through its PCM reader without opening an output device. The
example is a manual output-device check because CI must not emit sound.

## source

- [Oto v3 documentation](https://pkg.go.dev/github.com/ebitengine/oto/v3)
