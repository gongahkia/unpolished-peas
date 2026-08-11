# Reference rendering and image comparisons

`render.ReferenceBackend` is a deterministic CPU implementation of
`render.Backend` for command and image regression tests. It owns an RGBA8
target and accepts the same `render.Frame` produced for a graphics backend. It
does not select, exercise, or certify a GPU implementation.

```go
backend, err := render.NewReferenceBackend(320, 180)
if err != nil {
	return err
}
if err := backend.Render(frame); err != nil {
	return err
}
actual := backend.Snapshot()
comparison, err := render.CompareImages(expected, actual, render.ImageTolerance{})
if err != nil {
	return err
}
if !comparison.WithinTolerance {
	return fmt.Errorf("render regression: %+v", comparison)
}
```

## Deterministic contract

The reference backend processes every `Clear` before non-clear commands, then
sorts non-clear commands by layer while retaining submission order within a
layer. World-space commands translate by the negative frame camera position;
screen-space commands do not translate.

Sprites and tile maps use nearest-neighbour sampling from portable RGBA8 image
data. A zero sprite source selects the whole texture. `Sprite.Transform.Origin`
is a normalized Bounds pivot; zero scales mean one, negative scales mirror an
axis, and rotation is clockwise radians in screen coordinates after scaling
around that pivot. A zero-value transform preserves existing placement. The
reference backend inverse-maps destination pixel centres, so mirrored-sprite
coverage remains exact. Primitive coverage is
based on logical pixel centres: rectangles are half-open; filled circles include
a centre at or inside the radius; stroked circles cover the band from
`max(0, radius - width/2)` through `radius + width/2`; and lines include centres
at or within half the stroke width from their segment. Source and primitive
colors use straight-alpha source-over composition. Text uses the fixed
`basicfont.Face7x13` fallback and its position is the glyph baseline. Material
parameters are backend-defined and are not interpreted by the reference backend.

`TileMap.VisibleRange` conservatively selects whole cells that intersect a
target viewport in tile-map coordinates; a partially visible edge cell remains
in the range. The reference and transitional Ebit renderers use that range
after camera translation and before per-tile submission. It is culling only:
atlas coordinates, empty-tile behavior, and draw order are unchanged.
`Queue.DrawTileMap` rejects a non-negative atlas index outside the declared
atlas before rendering; negative values continue to mean empty cells.

`TextureStore.CreateRenderTarget` creates a transparent portable image with a
stable texture handle. A `TargetBackend` may render a complete `Frame` into it
with `RenderTo`; subsequent sprites can sample `target.Texture`. The reference
backend writes its deterministic result back to the store, while a renderer may
retain a native target cache. Sampling a target while writing the same target
is intentionally unspecified. Render targets retain normal frame camera, clip,
clear, ordering, and texture semantics.

`Queue.PushClip` and `Queue.PopClip` form a nested, screen-space clip stack.
The queue stores the effective intersection on each subsequent draw, rather
than relying on renderer-side push/pop ordering; a `Clear` remains un-clipped.
Clip bounds use the same half-open, logical-pixel-centre rule as rectangles and
apply after a world command's camera translation. `engine.CommandFrame` exposes
clips only from screen-space layers. The reference backend applies clips to
sprites, tiles, primitives, and both basic-font and atlas text; renderers must
preserve those semantics or document their difference.

These rules are intentionally explicit rather than a pixel-for-pixel promise
to Ebitengine or a future GPU renderer. A backend must document any semantic
difference and add a focused regression before relying on it.

## GPU integration tolerance

CPU reference tests use `ImageTolerance{}` and must be exact. A GPU integration
test may use non-zero `PerChannel` or `DifferentPixels` only when its test case
records the backend, driver, target format, reason for the tolerance, and the
first observed comparison result. `ImageComparison` reports the number and
first location of pixels outside the allowed per-channel delta, so a tolerance
does not hide an unbounded regression.

The current repository has no production GPU renderer or GPU image test.
Consequently, this helper establishes the comparison contract but does not turn
compile-only or single-machine WebGPU experiments into GPU test coverage.
