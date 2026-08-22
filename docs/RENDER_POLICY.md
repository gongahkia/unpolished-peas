# Renderer alpha, blend, and sampling policy

This policy defines the engine-owned 2D renderer foundation. It applies to the
embedded `sprite-2d@v1` WGSL asset and its private pipeline descriptors;
native format and driver behavior remain platform-specific.

## Inputs and alpha

`render.Image` pixels and `render.Color` values are portable, straight-alpha
RGBA8 values. A sprite tint is also straight alpha. The sprite shader samples
the texture, combines source and tint alpha, and returns premultiplied output:

```text
alpha = texture.a × tint.a
output.rgb = texture.rgb × tint.rgb × alpha
output.a = alpha
```

No public color-space tag exists yet, so the portable contract does not imply
a profile conversion. The selected backend must pair texture and presentation
formats consistently and document that mapping; the embedded shader itself
does not apply an implicit transfer conversion.

## Blend modes

Pipelines use premultiplied shader output. The default `source-over` state is
`source × 1 + destination × (1 - source alpha)` for both color and alpha.
`replace` uses source one and destination zero and is retained only for private
renderer work. `additive` adds source and destination premultiplied color and
alpha. `render.Sprite.Blend` and `render.TileMap.Blend` expose typed
`BlendSourceOver` and `BlendAdditive`; zero-value source-over retains existing
painter's-order behavior. Applications do not gain arbitrary blend equations,
shaders, or material parameters from this feature.

## Sampling

`render.Sprite.Sampling` and `render.TileMap.Sampling` expose nearest and
linear filtering for textured draws; the zero value is nearest. Text and
primitives remain fixed to nearest/source-over. Linear filtering uses
clamp-to-edge at the texture boundary, not at a sprite source rectangle. Games
using an atlas therefore need transparent padding or extruded edges to avoid
neighbouring cells bleeding into a linearly sampled tile. Neither policy
creates mipmaps, enables anisotropic filtering, or changes the texture address
policy; those require a later renderer feature and an explicit cache-key
revision.

## Validation and cache identity

WGSL sources are embedded and versioned. A selected private GPU adapter must
validate an asset with its real WGSL compiler before creating a native pipeline;
validation and creation errors retain the shader asset and underlying cause in
structured renderer diagnostics. Pipeline keys include asset name/version,
blend mode, sampling, the straight-alpha convention, target format, and target
sample count. Equivalent engine-owned pipeline requests targeting the same
attachment configuration reuse one device-local pipeline.
