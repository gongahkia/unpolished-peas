package render

import (
	"testing"

	"golang.org/x/image/font/gofont/goregular"
)

type testFontSource []byte

func (s testFontSource) Bytes() []byte { return append([]byte(nil), s...) }

func TestGlyphAtlasCachesFallbackAndPortablePages(t *testing.T) {
	atlas, err := NewGlyphAtlas(testFontSource(goregular.TTF), GlyphAtlasOptions{PageWidth: 64, PageHeight: 64, MaxGlyphs: 4, Size: 13})
	if err != nil {
		t.Fatal(err)
	}
	first, err := atlas.Glyph('A')
	if err != nil {
		t.Fatal(err)
	}
	second, err := atlas.Glyph('A')
	if err != nil {
		t.Fatal(err)
	}
	if first != second || atlas.GlyphCount() != 1 || atlas.Pages() != 1 {
		t.Fatalf("cached glyph=%+v repeated=%+v count=%d pages=%d", first, second, atlas.GlyphCount(), atlas.Pages())
	}
	fallback, err := atlas.Glyph(rune(0x10ffff))
	if err != nil {
		t.Fatal(err)
	}
	if !fallback.Fallback || atlas.GlyphCount() != 2 {
		t.Fatalf("fallback glyph=%+v count=%d", fallback, atlas.GlyphCount())
	}
	page, revision, ok := atlas.Page(first.Page)
	if !ok || revision == 0 || page.Width != 64 || page.Height != 64 || !hasAlpha(page) {
		t.Fatalf("atlas page=%+v revision=%d present=%t", page, revision, ok)
	}
}

func TestGlyphAtlasRejectsCacheExhaustion(t *testing.T) {
	atlas, err := NewGlyphAtlas(testFontSource(goregular.TTF), GlyphAtlasOptions{MaxGlyphs: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := atlas.Glyph('A'); err != nil {
		t.Fatal(err)
	}
	if _, err := atlas.Glyph('B'); err == nil {
		t.Fatal("glyph cache limit succeeded")
	}
}

func hasAlpha(image Image) bool {
	for index := 3; index < len(image.Pixels); index += 4 {
		if image.Pixels[index] != 0 {
			return true
		}
	}
	return false
}
