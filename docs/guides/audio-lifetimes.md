# Audio resources across scene transitions

Use `audio.unloadSound(handle)` and `audio.unloadMusic(handle)` when a level
or loading phase finishes with its audio. The host still owns Audio and its
resources; game code requests release through handles and never calls
Audio.deinit on a borrowed context service. Existing games that omit unload
retain their original host-lifetime behavior.

See the [call reference](../api/audio-save.md#core-Audio) for signatures and
the [audio guide](audio-assets.md) for formats, playback and availability.

## Runnable scene example

The [portable game](../../examples/audio_lifetime_game.zig) keeps a UI effect
across scene transitions, prepares incoming sound/music, then releases the
outgoing sources. It alternates WAV and OGG music. Space changes scene;
Escape pauses/resumes music. A transition also releases a paused old stream.

```sh
zig build run-audio-lifetime
zig build web-audio-lifetime -Dwith_sdl=false
python3 -m http.server --directory zig-out/audio-lifetime 8000
```

Open http://localhost:8000 and press Space to activate audio. A blocked
playback does not require reloading its source. The example handles
AudioUnavailable as recoverable; other failures propagate. If either incoming
load fails, it releases partial incoming data and retains the old scene.
After committing a scene, a playback failure leaves the new handles owned
by the game until cleanup. Failed init explicitly cleans up all loaded data.

The [desktop wrapper](../../examples/audio_lifetime.zig) forwards callbacks.
The [browser wrapper](../../examples/audio_lifetime_browser.zig) adds
test-only observations around the same game and normal browser runtime.
This is an audio-lifetime example, not a scene framework.

## Release contract

| Operation | Behavior |
| --- | --- |
| unloadSound | Stops all instances borrowing that sound, including paused, looping and overlapping instances; frees decoded PCM |
| unloadMusic | Stops all dependent WAV/OGG playbacks before freeing decoder/buffers and encoded source bytes |
| Successful release | Returns true; the loaded-resource handle and its dependent playback handles become stale |
| Invalid, stale or repeated release | Returns false and leaves other resources/playback unchanged |
| Released source passed to play/playMusic | Returns InvalidSound/InvalidMusic when output is ready; existing availability/options error precedence is preserved |
| Release while output is blocked/unavailable | Still works; no device or browser gesture is required |
| Empty registry slot | Retained as metadata and reused on a later load with a new generation |
| Host teardown | Stops remaining playback, frees remaining resources and all registry metadata |

Release does not stop unrelated effects or a different current music source.
Unloading a track that has been replaced does not stop its replacement.
Never-started, naturally completed and explicitly stopped sources can be
released too. AssetCollection cleanup remains independent of Audio.

Handles belong to one live Audio service. Do not use a handle with another
Audio instance or retain it across that service's teardown. The existing
handle representation is unchanged; it does not encode cross-service identity.
Do not access implementation registry entries or retain pointers into their
released data.

Call load/play/release and mixing from the serialized game/host thread.
Audio is not thread-safe. Resource management and decoding are not realtime
device-callback operations. Release allocates nothing and performs no device
access, but it synchronously scans retained playback slots and frees data.

Already queued PCM belongs to the SDL/WebAudio sink. Unload stops future
mixing from that resource; it does not retract those copied samples or flush
unrelated audio. A short queued tail may remain audible. Existing host queue
bounds and the one-active-high-level-music policy are unchanged.

## Memory bounds and failure behavior

Sound PCM and music source data are freed immediately on release. Active
Vorbis decoder and stream buffers are closed/freed first. The registry keeps
small stable slot objects and pointer-array capacity, and the mixer keeps
playback capacity. This metadata grows with the high-water mark of simultaneous
resources/playbacks, not the number of repeated transitions using those slots.
Host teardown releases the metadata. Load can still allocate/decode each time;
this API is resource release and slot reuse, not a decoded-content cache.

Per-resource byte/frame limits remain unchanged. The game chooses its total
simultaneous-resource budget. Loading an incoming scene before releasing the
old one temporarily retains both; the example reaches three sound slots
(persistent UI plus outgoing/incoming) and two music slots, then reuses them.

Sound and music generations are independent u32 counters per Audio. Generation
zero is reserved for unloaded slots. Counters never wrap: after issuing
4,294,967,295 generations for a resource kind, further loads of that kind
return AudioHandleExhausted. A failed registration may consume a generation.
Previously loaded resources remain usable and releasable. Keep handle fields
opaque and do not reset counters. Exhaustion-boundary tests run in native/Wasm.

Decode, allocation or generation failures release partial incoming data and
leave prior resources valid. A failed music start retains the previous active
stream. Unload is infallible apart from its true/false validity result.

## Reproduced growth and measured plateau

The original implementation was captured and run before modifying Audio on
Intel macOS 15.7.7, Zig 0.15.2. Each cycle loaded the existing blip WAV and
tone OGG, played/mixed them, then stopped playback. It retained:

| Cycles | Sound/music slots each | Native live allocator bytes |
| ---: | ---: | ---: |
| 1 | 1 | 36,902 |
| 8 | 8 | 290,022 |
| 64 | 64 | 2,315,942 |
| 256 | 256 | 9,262,758 |

The same workload with explicit release retains one slot of each kind and
**878 native / 574 Wasm bytes** at all four checkpoints. Live data returns to
zero after Audio.deinit. Native/Wasm record and check peak allocations too;
the release workload's peak must remain equal to its first-cycle peak:
204,478 native / 1,272,182 Wasm bytes in this run.
Native and Wasm sizes differ because metadata/pointers have different layouts.

These are requested bytes tracked through the Zig allocator, not process RSS.
Native stb_vorbis also uses its own C allocation internally, which is outside
that counter; its decoder is explicitly closed before source release. Wasm's
bounded decoder workspace goes through the tracked allocator. Wasm linear
memory does not shrink when freed; the harness separately checks that warmed
full lifecycles stop growing it. These measurements include the deliberate
no-release comparison, not only the small released-resource workload.

## Verification

```sh
zig build probe-audio-lifetime -Dwith_sdl=false --summary all
zig build test-audio-lifetime test-browser-audio-lifetime web-audio-lifetime \
  -Dwith_sdl=false -j2 --summary all
zig build test-audio test-music test-browser-audio test-browser-music \
  test-browser-audio-stream -Dwith_sdl=false -j2 --summary all
zig build test-sdl check-examples -j2 --summary all
script/test_native_audio_lifetime.sh
script/test_browser_audio_lifetime.sh
zig build docs-update-api -Dwith_sdl=false --summary all
zig build docs test-docs test-core-api -Dwith_sdl=false -j2 --summary all
```

The [shared probe](../../examples/audio_lifetime_probe.zig) verifies overlap,
paused/looping release, all six music states for WAV and OGG, stale/invalid
handles, source/playback-slot reuse, generation exhaustion, memory plateaus,
allocation failures, retained persistent audio and exact post-release PCM.
OGG stream output is checked against an independent complete decode before
release. The portable WAV PCM hash is compared between native/Wasm.
Native Debug and ReleaseFast execute the checks; Wasm repeats three complete
lifecycles and injects its own allocation failures.

The recorded native/Wasm failure walks exercised 20/29 allocation points.
The wider audio/core/docs/replay/reference-game suite passed 408 tests across
112 build steps. The native SDL suite passed 64 tests (including the queue
test, without a device skip), and all example compilation steps succeeded.

The native script requires a real display/audio-capable host. It runs eight
scene changes through SDL, verifies game cleanup before host teardown and uses
a fresh application UUID; cleanup removes only that test namespace.
The SDL suite also checks fresh queued PCM after release; that device-dependent
test skips if no output device is available. Browser checks use actual Chromium
keyboard events, autoplay retry, twelve transitions with paused outgoing music,
bounded source counts, finite nonzero PCM accepted by WebAudio and shutdown.
Device acceptance is not physical speaker-quality validation.

Default tests include native lifetime coverage; test-docs includes native/Wasm
compiled recipes. CI also runs Wasm lifetime and Chromium interaction checks.
The native device script remains an explicit hardware check. Diagnostics and
memory reports are retained under zig-out/diagnostics/audio-lifetime.

On this Intel macOS host, the native script completed eight SDL/Metal scene
transitions with audio ready and cleanup verified. Chromium 157 completed
twelve keyboard-driven transitions with paused outgoing music and accepted
36 nonzero PCM submissions before the recorded capture; shutdown stopped new
submissions. Submission counts depend on frame scheduling, not a fixed golden.

No asynchronous loading, crossfades, playlists, multiple high-level music
streams or changes to replay/audio-device timing are added.
