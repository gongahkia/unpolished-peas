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
data. A zero sprite source selects the whole texture. Primitive coverage is
based on logical pixel centres: rectangles are half-open; filled circles include
a centre at or inside the radius; stroked circles cover the band from
`max(0, radius - width/2)` through `radius + width/2`; and lines include centres
at or within half the stroke width from their segment. Source and primitive
colors use straight-alpha source-over composition. Text uses the fixed
`basicfont.Face7x13` fallback and its position is the glyph baseline. Material
parameters are backend-defined and are not interpreted by the reference backend.

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
