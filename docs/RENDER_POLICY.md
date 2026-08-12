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
`replace` uses source one and destination zero and is valid only when callers
know fragments are opaque. `additive` adds source and destination for both
color and alpha. These are private pipeline selections today; applications do
not gain user-authored blend/shader control from this foundation.

## Sampling

`nearest` selects nearest-texel sampling. `linear` selects linear filtering.
Neither selection creates mipmaps, enables anisotropic filtering, or changes
the texture address policy; those require a later renderer feature and an
explicit cache key revision.

## Validation and cache identity

WGSL sources are embedded and versioned. A selected private GPU adapter must
validate an asset with its real WGSL compiler before creating a native pipeline;
validation and creation errors retain the shader asset and underlying cause in
structured renderer diagnostics. Pipeline keys include asset name/version,
material name and canonical finite parameters, blend mode, sampling, and the
straight-alpha convention, target format, and target sample count. Equivalent
material parameter maps targeting the same attachment configuration reuse one
device-local pipeline.
