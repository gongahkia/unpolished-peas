# Render surfaces

`up.graphics.RenderSurface` is a persistent, Peas-owned offscreen 2D Canvas.
It is useful for low-resolution pixel-art composition, minimaps, temporary
authored layers, and other ordinary 2D sub-composition. It is deliberately not
a public framebuffer, texture, render pass, or GPU-resource API.

The v0.1 implementation owns a CPU Canvas pixel buffer. This gives the same
observable drawing and composition semantics in headless tests, SDL GPU,
WebGL 2, and WebGPU: the normal presentation path uploads the already
composed main Canvas. It is therefore not yet a GPU intermediate target for
the staged material/post-pass renderer.

## Create, draw, compose

Create a surface with an allocator, retain it in game-owned state, and release
it once with `deinit`:

```zig
var world = try up.graphics.RenderSurface.init(allocator, 320, 180);
defer world.deinit();

const target = world.canvas();
target.clear(up.core.Color.rgb(20, 28, 44));
target.fillRect(10, 10, 12, 12, up.core.Color.white);

try screen.drawSurface(&world, .{
    .x = 0,
    .y = 0,
    .width = 1280,
    .height = 720,
    .filter = .nearest,
});
```

New surfaces start as transparent black. They have fixed non-zero `u32`
dimensions; v0.1 has no resize operation, so recreate a surface when its size
must change. The caller owns both the allocator choice and surface lifetime.
There is no global surface registry, implicit per-frame allocation, or hidden
garbage collection.

`surface.canvas()` borrows the contained Canvas. All ordinary Canvas drawing
operations work on that target, including clear, primitives, sprites, atlas
frames, built-in text, clips, and alpha/additive blend state. A draw becomes
visible to a later `drawSurface` call as soon as the Canvas call returns.
There is no `begin`/`end` target stack and no nested-target mode in v0.1.

## Composition and sampling

`Canvas.drawSurface` takes `SurfaceDrawOptions`:

- `x`, `y`, `width`, and `height` are the explicit logical-pixel destination
  rectangle. Zero or dimensions larger than `i32` are rejected with
  `error.InvalidSurfaceDrawSize`.
- `tint` defaults to white and is multiplied into sampled RGBA before the
  destination Canvas applies its active blend mode and clip.
- `filter` defaults to `.nearest`, which preserves pixel edges exactly.
  `.linear` performs channel interpolation for smoother scaling.

The source surface may not be drawn onto its own contained Canvas; that
feedback loop returns `error.SurfaceSelfSampling`. Drawing one surface onto a
different surface is valid and immediately samples the source's current
contents. Multiple owned surfaces are independent.

Canvas retains its existing source-over alpha and additive blend semantics;
surfaces do not introduce a different alpha model. There is no source-rect,
rotation, arbitrary transform, mip chain, custom pixel format, depth/stencil,
or public surface readback API in this initial surface contract.

For low-resolution pixel art, use nearest filtering and prefer exact integer
upscales. The CPU implementation has dedicated 1:1 and integer-nearest paths
while preserving the same tint, clip, and blend result as ordinary sampling.
On the locally tested Intel macOS host, 320×180 to 1280×720 nearest composition
measured about 1.9 ms in a ReleaseFast internal benchmark; linear composition
of that same destination measured about 23 ms. These are local observations,
not a cross-machine budget. Keep linear full-HD surface work bounded until a
real workload demonstrates a reason to evolve the design.

## Advanced renderer boundary

Render surfaces are part of the ordinary CPU Canvas path. They are not
currently accepted by `Renderer2D` material sprites, GPU-material bindings,
GPU particles, or final GPU post passes. Those advanced queues remain tied to
the main presentable renderer destination. The CPU `PostProcessChain` accepts
a Canvas and can be deliberately applied to `surface.canvas()` when its
reference effects are desired, but this does not make the surface a GPU post
input.

## Headless and regression tests

Because a surface is a Canvas-backed value, it works without SDL, a browser,
or a GPU. Headless tests can draw a surface, compose it onto their main Canvas,
and assert final pixels exactly.

When a test attaches a `CanvasTrace`, a surface composition records its source
dimensions and a deterministic digest of the current source pixels, then its
destination geometry, tint, and filter. It never records the surface address
or a backend handle. Thus separately allocated equal surfaces compare equally;
mutating surface content changes the trace resource field and hash. Trace
capture remains opt-in, so normal games do not hash or copy surface commands.

See [Testing](testing.md) for the distinction between simulation-state,
logical-Canvas, and renderer/pixel regression tests. Run
`zig build run-render-surface` for the compact nearest-scaled example; it
writes `zig-out/render-surface.ppm`.
