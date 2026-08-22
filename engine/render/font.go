package render

import (
	"fmt"
	"image"
	"image/color"
	"sync"

	"golang.org/x/image/draw"
	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

// FontSource supplies validated encoded OpenType or TrueType bytes. assets.Font
// satisfies this interface without making render depend on the assets package.
type FontSource interface{ Bytes() []byte }

// GlyphAtlasOptions defines the bounded raster cache for one font face. A zero
// PageWidth/PageHeight uses 256 pixels, a zero MaxPages uses one page, a zero
// MaxGlyphs uses 256 glyphs, a zero Size uses 13 points, and a zero Fallback
// uses '?'. Glyphs are rasterized with no hinting for deterministic output.
type GlyphAtlasOptions struct {
	PageWidth, PageHeight int
	MaxPages              int
	MaxGlyphs             int
	Size                  float64
	Fallback              rune
}

// Glyph identifies one cached glyph in an atlas page. Source is in physical
// atlas pixels; Offset and Advance are logical pixels relative to a text
// baseline. Fallback reports that the requested rune used the fallback glyph.
type Glyph struct {
	Page     int
	Source   Rect
	Offset   Vec2
	Advance  float64
	Fallback bool
}

// GlyphAtlas owns rasterized glyphs and portable non-premultiplied RGBA8 page
// pixels. It is safe for concurrent lookup, though render backends normally
// use it from their render owner goroutine.
type GlyphAtlas struct {
	mu      sync.Mutex
	face    font.Face
	options GlyphAtlasOptions
	glyphs  map[rune]Glyph
	pages   []*atlasPage
	misses  map[rune]bool
}

type atlasPage struct {
	image        *image.NRGBA
	nextX, nextY int
	rowHeight    int
	revision     uint64
}

// NewGlyphAtlas parses source and creates an empty bounded cache.
func NewGlyphAtlas(source FontSource, options GlyphAtlasOptions) (*GlyphAtlas, error) {
	if source == nil {
		return nil, fmt.Errorf("glyph atlas font source must not be nil")
	}
	data := source.Bytes()
	if len(data) == 0 {
		return nil, fmt.Errorf("glyph atlas font source must not be empty")
	}
	options = normalizeGlyphAtlasOptions(options)
	if options.PageWidth < 8 || options.PageHeight < 8 || options.MaxPages < 1 || options.MaxGlyphs < 1 || !finite(options.Size) || options.Size <= 0 {
		return nil, fmt.Errorf("glyph atlas options are invalid")
	}
	parsed, err := opentype.Parse(data)
	if err != nil {
		return nil, fmt.Errorf("parse glyph atlas font: %w", err)
	}
	face, err := opentype.NewFace(parsed, &opentype.FaceOptions{Size: options.Size, DPI: 72, Hinting: font.HintingNone})
	if err != nil {
		return nil, fmt.Errorf("create glyph atlas face: %w", err)
	}
	return &GlyphAtlas{face: face, options: options, glyphs: make(map[rune]Glyph), misses: make(map[rune]bool)}, nil
}

// Glyph returns the cached glyph for value, rasterizing it on first use. A
// missing rune uses the configured fallback when available; cache exhaustion
// returns an error rather than evicting a previously rendered glyph.
func (a *GlyphAtlas) Glyph(value rune) (Glyph, error) {
	if a == nil {
		return Glyph{}, fmt.Errorf("glyph atlas must not be nil")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if glyph, ok := a.glyphs[value]; ok {
		return glyph, nil
	}
	if a.misses[value] {
		return Glyph{}, fmt.Errorf("glyph atlas has no glyph for %q", value)
	}
	if len(a.glyphs) >= a.options.MaxGlyphs {
		return Glyph{}, fmt.Errorf("glyph atlas reached its %d glyph limit", a.options.MaxGlyphs)
	}
	glyph, err := a.rasterize(value, false)
	if err == nil {
		a.glyphs[value] = glyph
		return glyph, nil
	}
	if value != a.options.Fallback {
		fallback, fallbackErr := a.rasterize(a.options.Fallback, true)
		if fallbackErr == nil {
			a.glyphs[value] = fallback
			return fallback, nil
		}
	}
	a.misses[value] = true
	return Glyph{}, err
}

// Page returns a copy of one portable atlas page and its monotonically
// increasing revision. Backends use the revision to refresh native uploads.
func (a *GlyphAtlas) Page(index int) (Image, uint64, bool) {
	if a == nil {
		return Image{}, 0, false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if index < 0 || index >= len(a.pages) {
		return Image{}, 0, false
	}
	page := a.pages[index]
	portable, err := NewImage(page.image.Bounds().Dx(), page.image.Bounds().Dy(), page.image.Pix)
	if err != nil {
		return Image{}, 0, false
	}
	return portable, page.revision, true
}

// Pages reports the number of allocated atlas pages.
func (a *GlyphAtlas) Pages() int {
	if a == nil {
		return 0
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.pages)
}

// GlyphCount reports the number of requested runes retained in the cache.
func (a *GlyphAtlas) GlyphCount() int {
	if a == nil {
		return 0
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.glyphs)
}

func (a *GlyphAtlas) rasterize(value rune, fallback bool) (Glyph, error) {
	destination, mask, maskPoint, advance, ok := a.face.Glyph(fixed.Point26_6{}, value)
	if !ok || mask == nil {
		return Glyph{}, fmt.Errorf("glyph atlas has no glyph for %q", value)
	}
	width, height := destination.Dx(), destination.Dy()
	if width < 0 || height < 0 || width+2 > a.options.PageWidth || height+2 > a.options.PageHeight {
		return Glyph{}, fmt.Errorf("glyph %q exceeds atlas page dimensions", value)
	}
	pageIndex, bounds, err := a.place(width, height)
	if err != nil {
		return Glyph{}, err
	}
	page := a.pages[pageIndex]
	if width > 0 && height > 0 {
		draw.DrawMask(page.image, image.Rect(int(bounds.X), int(bounds.Y), int(bounds.X+bounds.W), int(bounds.Y+bounds.H)), image.NewUniform(color.NRGBA{R: 255, G: 255, B: 255, A: 255}), image.Point{}, mask, maskPoint, draw.Src)
		page.revision++
	}
	return Glyph{Page: pageIndex, Source: bounds, Offset: Vec2{X: float64(destination.Min.X), Y: float64(destination.Min.Y)}, Advance: float64(advance) / 64, Fallback: fallback}, nil
}

func (a *GlyphAtlas) place(width, height int) (int, Rect, error) {
	for index, page := range a.pages {
		if page.nextX+width+1 > a.options.PageWidth {
			page.nextX, page.nextY, page.rowHeight = 1, page.nextY+page.rowHeight+1, 0
		}
		if page.nextY+height+1 > a.options.PageHeight {
			continue
		}
		bounds := Rect{X: float64(page.nextX), Y: float64(page.nextY), W: float64(width), H: float64(height)}
		page.nextX += width + 1
		page.rowHeight = maxAtlasInt(page.rowHeight, height)
		return index, bounds, nil
	}
	if len(a.pages) >= a.options.MaxPages {
		return 0, Rect{}, fmt.Errorf("glyph atlas reached its %d page limit", a.options.MaxPages)
	}
	page := &atlasPage{image: image.NewNRGBA(image.Rect(0, 0, a.options.PageWidth, a.options.PageHeight)), nextX: 1, nextY: 1}
	a.pages = append(a.pages, page)
	return a.place(width, height)
}

func normalizeGlyphAtlasOptions(options GlyphAtlasOptions) GlyphAtlasOptions {
	if options.PageWidth == 0 {
		options.PageWidth = 256
	}
	if options.PageHeight == 0 {
		options.PageHeight = 256
	}
	if options.MaxPages == 0 {
		options.MaxPages = 1
	}
	if options.MaxGlyphs == 0 {
		options.MaxGlyphs = 256
	}
	if options.Size == 0 {
		options.Size = 13
	}
	if options.Fallback == 0 {
		options.Fallback = '?'
	}
	return options
}

func maxAtlasInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}
