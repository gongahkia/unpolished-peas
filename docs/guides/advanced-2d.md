# Advanced 2D

The v0.1 advanced layer keeps the engine in 2D. It adds runtime shader-source bundles, CPU-reference post effects, deterministic particles, and mixer-driven music. It does not expose meshes, compute pipelines, raw GPU objects, or a scene/ECS model.

## Materials and post effects

`ShaderSourceBundle` requires HLSL for a native SDL GPU target, GLSL ES for WebGL 2, and WGSL for WebGPU. All three variants must declare the same named texture/uniform manifest. `Material.init` validates that portable package before a future renderer selects its target source; an invalid source, missing entry point, duplicate binding, or invalid binding name fails rather than choosing another backend's code.

The portable reference effects execute on `Canvas`, so their behavior is shared by headless tests, the desktop Canvas presenter, and the browser Canvas upload path. A chain owns a reusable blur scratch surface and applies effects in declaration order.

```zig
const up = @import("unpolished-peas");

var chain = try up.graphics.PostProcessChain.init(allocator, &.{
    .{ .pixelate = 2 },
    .{ .crt = .{ .scanline_strength = 20 } },
});
defer chain.deinit();
try chain.apply(canvas);
```

Custom source bundles are validated and retained as the portable material contract. The present Canvas renderer does not execute arbitrary user shader code: only the documented CPU-reference effects have cross-target execution coverage. Do not treat source-bundle validation as a claim that arbitrary HLSL, GLSL ES, and WGSL programs are semantically interchangeable.

## Particles

`ParticleSystem` has deterministic CPU simulation. Its seed, fixed-step update, particle lifetime, velocity, gravity, size, and colour interpolation produce the same particle state on every target. `submit` appends compact per-particle data to `Renderer2D`; the SDL GPU, WebGL 2, and WebGPU presenters draw each contiguous blend batch with one instanced quad call. `draw` remains the deterministic Canvas reference path.

```zig
var particles = try up.graphics.ParticleSystem.init(allocator, .{
    .seed = 42,
    .position = .{ .x = 80, .y = 45 },
    .spawn_rate = 24,
    .gravity = .{ .x = 0, .y = 18 },
    .start_color = up.core.Color.rgb(255, 198, 74),
    .end_color = up.core.Color.transparent,
});
defer particles.deinit();

try particles.update(1.0 / 60.0);
const renderer = try context.requireRenderer2D();
try particles.submit(renderer);
```

The system reserves its configured capacity during initialisation, and post-process blur reuses its scratch buffer. The unit suite verifies retained capacity, blend-batch construction, and Canvas reference output. `Renderer2D` is available through `GameContext` in the SDL GPU and browser runtimes; the OpenGL preview presenter explicitly rejects queued advanced draws rather than silently falling back to CPU rendering.

## Audio and music

`assets.Sound` accepts WAV and OGG on native targets. `assets.Music` exposes streamed WAV and OGG music, and `assets.AudioMixer` exposes master, SFX, music, and custom buses with volume, pan, pause/resume, fade, and stale-handle checks. `SoundOptions` now accepts an optional bus and pan.

Browser builds can decode WAV and OGG/Vorbis with the same Zig mixer used by native builds, then submit one bounded PCM buffer through `assets.AudioStream`. `Music.decodeOgg` accepts owned asset bytes for freestanding hosts and preserves its source for streamed mixer playback. Browser audio must first be activated by a user gesture; `AudioStream.submit` returns `false` while the browser host is suspended or its queue is full. The browser decoder uses a fixed 1 MiB caller-owned Vorbis workspace; unusually complex streams that exhaust it fail with `OggDecoderStorageExhausted` rather than allocating through an unavailable C runtime.

```zig
var mixer = try up.assets.AudioMixer.init(allocator, .{});
defer mixer.deinit();
var stream = try up.assets.AudioStream.init(allocator, .{ .frames_per_submit = 1024 });
defer stream.deinit();

_ = try mixer.playSound(&sound, .{ .bus = up.assets.AudioMixer.sfxBus(), .pan = -0.25 });
_ = try stream.submit(&mixer); // false until browser activation; native uses its adapter sink
```

## Verification and parity

Parity means the same public API, deterministic particle state, audio control semantics, and Canvas capture behavior. It does not mean byte-identical output for arbitrary GPU shaders on different drivers. Run `zig build test`, `zig build test-browser-ogg-decode`, `zig build browser`, `zig build test-browser-host`, and `zig build test-browser-webgpu` for the fast contract checks. Browser proof-game and real-GPU checks remain separate capability jobs.
