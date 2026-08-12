# Portable text and glyph atlases

`assets.DecodeFont` validates and retains OpenType or TrueType source bytes.
Pass its `assets.Font` result to `render.NewGlyphAtlas`; `assets.Font` satisfies
the renderer's `render.FontSource` boundary without a package import cycle.

```go
font, _ := assets.Load(manager, "fonts/ui.ttf", assets.DecodeFont)
source, _ := assets.Get(manager, font)
atlas, err := render.NewGlyphAtlas(source, render.GlyphAtlasOptions{
    Size: 16, PageWidth: 512, PageHeight: 512, MaxPages: 2, MaxGlyphs: 512,
})
if err != nil { return err }
_ = frame.DrawText(render.TextDraw{Position: render.Vec2{X: 8, Y: 24}, Value: "start", Color: white, Atlas: atlas})
```

An atlas uses non-premultiplied RGBA8 pages. Both the reference backend and the
engine-owned WebGPU renderer sample those pages; the latter owns private GPU
uploads and cache entries. Glyphs are rasterized with no hinting, so the
reference backend provides deterministic image-test output for a pinned font
file and atlas options.

## Cache and missing-glyph policy

Glyphs are inserted on first use and retained until the atlas is discarded.
There is no eviction. `MaxGlyphs` and `MaxPages` are hard limits: a new glyph
after either limit returns a contextual error instead of silently dropping or
changing a previously rendered glyph. Zero-valued options select one 256×256
page, 256 glyphs, 13-point text, and `?` as the fallback rune.

If a requested rune is absent, the atlas attempts its configured fallback and
marks the returned `render.Glyph` as `Fallback`. If that glyph is also absent,
or the cache is full, text rendering returns an error. Complex shaping,
bidirectional layout, line wrapping, font fallback chains, and GPU atlas
resource recreation are outside this implementation.
