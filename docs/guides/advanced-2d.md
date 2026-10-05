# Advanced 2D

The v0.1 advanced layer keeps the engine in 2D. It adds executable staged materials, GPU post passes, CPU-reference post effects, deterministic particles, and mixer-driven music. It does not expose meshes, compute pipelines, raw GPU objects, or a scene/ECS model.

## Materials and post effects

`Material.initStages` creates an executable 2D material from vertex and fragment `MaterialStage` values. Each stage contains AOT SPIR-V, DXBC, and metallib bytes for desktop plus GLSL ES and WGSL source for WebGL 2 and WebGPU. SDL GPU selects and consumes the matching precompiled native artifact; it does not invoke an HLSL, Metal, or SPIR-V compiler at runtime. Browser hosts compile their GLSL ES or WGSL source when the material pipeline is first used.

`AssetStore.loadMaterial("effect.upmat")` loads the generated runtime manifest. It exposes a `MaterialHandle`; call `tryMaterial` each frame before queueing a draw so development reloads can safely replace its backing program. `reloadChanged` watches the manifest and all ten stage artifacts. An invalid rebuild leaves the last working material in place and emits a failed reload event.

Use `peas shader compile <linux|windows|macos> <source.upshader> <output-directory>` on the corresponding CI platform, then `peas shader assemble <source.upshader> <artifact-directory> <output.upmat>` after all three artifact jobs are available. The assembler rejects a missing native artifact, so a release cannot accidentally ship source-only desktop materials.

The material binding list is ordered and starts with `texture:source`. A material sprite supplies that image; a post pass supplies the previous composed frame. Further bindings are named textures or sixteen-byte-padded std140 uniform blocks. WebGL uses the declared texture names and uniform-block names. WebGPU assigns each texture/sampler pair consecutively from bindings 0/1, then assigns uniform blocks after all texture pairs. SDL GPU follows the same declaration order for fragment samplers and uniform slots. Vertex inputs are position, UV, and tint at locations 0, 1, and 2.

```zig
const handle = try assets.loadMaterial("shaders/wave.upmat");
const material = try assets.tryMaterial(handle);
const renderer = try context.requireRenderer2D();

try renderer.drawMaterialSprite(.{
    .material = material,
    .image = player_image,
    .x = 40,
    .y = 24,
    .width = 32,
    .height = 32,
    .bindings = &.{.{ .name = "palette", .value = .{ .texture = .{ .image = palette_image } } }},
});
try renderer.addPostPass(.{ .material = material });
```

The renderer executes Canvas commands and ordinary sprites, material sprites, particles, then post passes. Every post pass samples the final composed frame through `source` and writes to the alternate RGBA8 target; only the last target is presented or captured. The OpenGL preview presenter rejects this advanced queue. It does not silently emulate materials on the CPU.

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

`ShaderSourceBundle` and `Material.init` remain validation-only compatibility APIs. They cannot be submitted as executable materials; use staged AOT assets instead. `PostProcessChain` remains the CPU Canvas reference for the built-in effects and headless tests. Arbitrary material output is intentionally not byte-identical across GPU drivers, shader compilers, or browser implementations.

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

The system reserves its configured capacity during initialisation, and post-process blur reuses its scratch buffer. The unit suite verifies retained capacity, blend-batch construction, and Canvas reference output. A local Intel macOS SDL GPU proof submitted 5,000 additive particles as one contiguous batch for 600 bounded frames; it is evidence of the instanced particle path, not a feature-equivalent generic Canvas-sprite throughput comparison. `Renderer2D` is available through `GameContext` in the SDL GPU and browser runtimes; the OpenGL preview presenter explicitly rejects queued advanced draws rather than silently falling back to CPU rendering.

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

Parity means the same public API, binding contract, deterministic particle state, audio control semantics, and Canvas capture behavior. It does not mean byte-identical output for arbitrary GPU shaders on different drivers. Run `zig build test`, `zig build test-browser-ogg-decode`, `zig build browser`, `zig build test-browser-host`, and `zig build test-browser-webgpu` for the fast contract checks. Browser proof-game and real-GPU checks remain separate capability jobs.
