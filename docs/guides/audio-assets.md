# Stable audio assets

The v0.1 audio subset loads RIFF/WAVE sounds only. Supported samples are mono or stereo PCM 8-, 16-, 24-, or 32-bit, or 32-bit IEEE float. A source is at most 32 MiB and decodes to at most 4,194,304 stereo frames. `AssetStore.loadSound` accepts `.wav`; malformed, unsupported, empty, or over-limit sources fail before playback. The browser reports `asset_load_failed:audio_v1` for any asset-load failure.

Loaded sounds use `SoundOptions{ .volume = 0...1, .loop = bool }`. The desktop adapter plays a sound and returns a `PlaybackHandle`; `stop(handle)` returns `true` once and `false` for a stale handle. Browser sound playback has matching load, play, stop, stale-stop, and recoverable-failure outcomes through the browser host audio adapter. The shared `src/fixtures/audio/stable-audio-v1.json` fixture is exercised by native and browser tests.

Browsers can create an `AudioContext` in a suspended state before a user interaction. The host activates audio from canvas pointer input or keyboard/touch input and rejects playback until its context is running; a later activation can recover a suspended context. This follows the [Web Audio context lifecycle](https://www.w3.org/TR/webaudio-1.1/) and documented [browser autoplay policy](https://developer.chrome.com/blog/autoplay).

`Music`, buses, panning, fades, streaming, and device-recovery controls are not in the v0.1 root API. They remain adapter implementation details and must not be used by a stable-core consumer.

Run `zig build test` and `zig build test-browser-audio` to validate the fixture and browser lifecycle.
