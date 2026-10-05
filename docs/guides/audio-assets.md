# Audio

## GameProtocol sound effects

`GameContext.audio` is Peas's small, backend-neutral sound-effect capability.
Load a short WAV once during `Game.init`, retain its handle in game state, and
reuse it from gameplay code:

```zig
if (ctx.audio) |audio| {
    self.pickup = try audio.loadWav(@embedFile("pickup.wav"));
}

// Later, for a gameplay event:
if (ctx.audio) |audio| {
    _ = audio.play(self.pickup, .{ .volume = 0.5 }) catch {};
}
```

`Audio` owns decoded sounds and releases them when its host shuts down; games
own only `Audio.SoundHandle` values. `play` creates independent instances, so
the same effect may overlap. Volume is `0.0...1.0`; `.loop = true` repeats an
effect until `audio.stop(handle)`. Decoding happens on `loadWav`, never in the
normal play path.

Audio is optional output, not deterministic simulation state. A headless run
has a device-free logical host. Desktop systems without an output device, and
browsers before their first user gesture, report a recoverable
`error.AudioUnavailable` from `play`; the game should remain playable. Replays
reproduce the gameplay event that requested a sound, not sample-exact speaker
timing.

The portable high-level path is embedded WAV bytes because browser fetch is
asynchronous while `Game.init` is not. `AssetStore` uses explicit native
runtime roots and never treats the current working directory as an implicit
asset root. The simple `GameContext.audio` capability is deliberately
short-SFX oriented. The separately frozen `assets.Sound`, `Music`,
`AudioMixer`, and `AudioStream` declarations are advanced asset/mixer APIs,
not required starter-game plumbing.

## Existing stable asset and mixer APIs

The native asset/mixer path loads RIFF/WAVE and OGG/Vorbis sounds. WAV
supports mono or stereo PCM 8-, 16-, 24-, or 32-bit, or 32-bit IEEE float. A
source is at most 32 MiB and decodes to at most 4,194,304 stereo frames.
`AssetStore.loadSound` accepts `.wav` and `.ogg`; malformed, unsupported,
empty, or over-limit sources fail before playback. The browser reports
`asset_load_failed:audio_v1` for any asset-load failure.

Loaded sounds use `SoundOptions{ .bus, .volume = 0...1, .pan = -1...1, .loop = bool }`. `AudioMixer` owns master, SFX, music, and custom buses, and plays sounds or streamed `Music` with volume, pan, fades, pause/resume, and stale-handle checks. The desktop adapter plays a sound and returns a `PlaybackHandle`; `stop(handle)` returns `true` once and `false` for a stale handle. The shared `src/fixtures/audio/stable-audio-v1.json` fixture is exercised by native and browser tests.

Browsers can create an `AudioContext` in a suspended state before a user interaction. The host activates audio from canvas pointer input or keyboard/touch input and rejects playback until its context is running; a later activation can recover a suspended context. This follows the [Web Audio context lifecycle](https://www.w3.org/TR/webaudio-1.1/) and documented [browser autoplay policy](https://developer.chrome.com/blog/autoplay).

For freestanding browser builds, `AudioStream` submits PCM mixed by the same
`AudioMixer` to the host. Embedded WAV and OGG/Vorbis decoding are supported by
the browser core; the Vorbis decoder uses a bounded 1 MiB caller workspace.
That is embedded-data decoding, not asynchronous browser asset loading or a
browser-codec fallback.

Run `zig build test` and `zig build test-browser-audio` to validate the fixture and browser lifecycle.
