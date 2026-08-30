# Stable audio assets

The v0.1 audio subset loads RIFF/WAVE and OGG/Vorbis sounds on native targets. WAV supports mono or stereo PCM 8-, 16-, 24-, or 32-bit, or 32-bit IEEE float. A source is at most 32 MiB and decodes to at most 4,194,304 stereo frames. `AssetStore.loadSound` accepts `.wav` and `.ogg`; malformed, unsupported, empty, or over-limit sources fail before playback. The browser reports `asset_load_failed:audio_v1` for any asset-load failure.

Loaded sounds use `SoundOptions{ .bus, .volume = 0...1, .pan = -1...1, .loop = bool }`. `AudioMixer` owns master, SFX, music, and custom buses, and plays sounds or streamed `Music` with volume, pan, fades, pause/resume, and stale-handle checks. The desktop adapter plays a sound and returns a `PlaybackHandle`; `stop(handle)` returns `true` once and `false` for a stale handle. The shared `src/fixtures/audio/stable-audio-v1.json` fixture is exercised by native and browser tests.

Browsers can create an `AudioContext` in a suspended state before a user interaction. The host activates audio from canvas pointer input or keyboard/touch input and rejects playback until its context is running; a later activation can recover a suspended context. This follows the [Web Audio context lifecycle](https://www.w3.org/TR/webaudio-1.1/) and documented [browser autoplay policy](https://developer.chrome.com/blog/autoplay).

For freestanding browser builds, `AudioStream` submits PCM mixed by the same `AudioMixer` to the host. WAV remains the browser-supported decoded source. OGG/Vorbis is rejected in the browser core because the native decoder currently depends on a C runtime that the freestanding build does not provide. This is an explicit capability limit, not a fallback to browser codec behavior.

Run `zig build test` and `zig build test-browser-audio` to validate the fixture and browser lifecycle.
