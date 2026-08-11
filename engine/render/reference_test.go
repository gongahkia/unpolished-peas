package render

import (
	"errors"
	"testing"

	"github.com/gongahkia/72/engine/diagnostics"
	"golang.org/x/image/font/gofont/goregular"
)

func TestReferenceBackendUsesClearAndStableLayerOrder(t *testing.T) {
	backend := newReferenceBackend(t, 1, 1)
	var queue Queue
	if err := queue.FillRect(2, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}, Color: Color{R: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	queue.Clear(Color{B: 255, A: 255})
	if err := queue.FillRect(1, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}, Color: Color{G: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillRect(2, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}, Color: Color{B: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue}); err != nil {
		t.Fatal(err)
	}
	if got, want := referencePixel(t, backend.Snapshot(), 0, 0), (Color{B: 255, A: 255}); got != want {
		t.Fatalf("ordered pixel = %+v, want %+v", got, want)
	}
}

func TestReferenceBackendRendersTextFromGlyphAtlas(t *testing.T) {
	atlas, err := NewGlyphAtlas(testFontSource(goregular.TTF), GlyphAtlasOptions{Size: 13})
	if err != nil {
		t.Fatal(err)
	}
	backend := newReferenceBackend(t, 24, 18)
	var queue Queue
	if err := queue.DrawText(0, ScreenSpace, TextDraw{Position: Vec2{X: 2, Y: 14}, Value: "A", Color: Color{R: 255, G: 255, B: 255, A: 255}, Atlas: atlas}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue}); err != nil {
		t.Fatal(err)
	}
	if atlas.GlyphCount() != 1 || atlas.Pages() != 1 || !referenceRegionHasColor(backend.Snapshot(), 2, 1, 12, 14, Color{R: 255, G: 255, B: 255, A: 255}) {
		t.Fatalf("atlas text was not rendered: glyphs=%d pages=%d", atlas.GlyphCount(), atlas.Pages())
	}
}

func TestReferenceBackendMirrorsSpriteAroundNormalizedPivot(t *testing.T) {
	backend := newReferenceBackend(t, 2, 1)
	store := NewTextureStore()
	texture, err := store.Create(mustReferenceImage(t, 2, 1, []byte{255, 0, 0, 255, 0, 255, 0, 255}))
	if err != nil {
		t.Fatal(err)
	}
	var queue Queue
	if err := queue.DrawSprite(0, ScreenSpace, Sprite{Texture: texture, Bounds: Rect{W: 2, H: 1}, Tint: Color{R: 255, G: 255, B: 255, A: 255}, Transform: SpriteTransform{Origin: Vec2{X: .5, Y: .5}, ScaleX: -1}}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue, Textures: store}); err != nil {
		t.Fatal(err)
	}
	if got, want := referencePixel(t, backend.Snapshot(), 0, 0), (Color{G: 255, A: 255}); got != want {
		t.Fatalf("mirrored left pixel = %+v, want %+v", got, want)
	}
	if got, want := referencePixel(t, backend.Snapshot(), 1, 0), (Color{R: 255, A: 255}); got != want {
		t.Fatalf("mirrored right pixel = %+v, want %+v", got, want)
	}
}

func TestReferenceBackendRendersSpritesTilesPrimitivesAndText(t *testing.T) {
	backend := newReferenceBackend(t, 14, 14)
	store := NewTextureStore()
	texture, err := store.Create(mustReferenceImage(t, 2, 1, []byte{
		255, 0, 0, 255,
		0, 255, 0, 255,
	}))
	if err != nil {
		t.Fatal(err)
	}
	white := Color{R: 255, G: 255, B: 255, A: 255}
	var queue Queue
	queue.Clear(Color{})
	if err := queue.DrawSprite(0, ScreenSpace, Sprite{Texture: texture, Bounds: Rect{X: 0, Y: 0, W: 4, H: 1}, Tint: white}); err != nil {
		t.Fatal(err)
	}
	if err := queue.DrawTileMap(0, ScreenSpace, TileMap{
		Texture: texture, Atlas: Vec2{X: 2, Y: 1}, TileSize: Vec2{X: 1, Y: 1}, Columns: 2,
		Tiles: []int{1, 0}, Bounds: Rect{X: 4, Y: 0, W: 2, H: 1}, Tint: white,
	}); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{X: 0, Y: 2, W: 2, H: 2}, Color: Color{R: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.StrokeRect(0, ScreenSpace, RectDraw{Bounds: Rect{X: 3, Y: 2, W: 3, H: 3}, Width: 1, Color: Color{G: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillCircle(0, ScreenSpace, CircleDraw{Center: Vec2{X: 2, Y: 7}, Radius: 1, Color: Color{B: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.StrokeLine(0, ScreenSpace, LineDraw{Start: Vec2{X: 5, Y: 7}, End: Vec2{X: 8, Y: 7}, Width: 1, Color: white}); err != nil {
		t.Fatal(err)
	}
	if err := queue.DrawText(0, ScreenSpace, TextDraw{Position: Vec2{X: 9, Y: 13}, Value: "A", Color: white}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue, Textures: store}); err != nil {
		t.Fatal(err)
	}
	image := backend.Snapshot()
	for x := 0; x < 2; x++ {
		if got, want := referencePixel(t, image, x, 0), (Color{R: 255, A: 255}); got != want {
			t.Fatalf("scaled sprite pixel %d = %+v, want %+v", x, got, want)
		}
	}
	for x := 2; x < 4; x++ {
		if got, want := referencePixel(t, image, x, 0), (Color{G: 255, A: 255}); got != want {
			t.Fatalf("scaled sprite pixel %d = %+v, want %+v", x, got, want)
		}
	}
	if got, want := referencePixel(t, image, 4, 0), (Color{G: 255, A: 255}); got != want {
		t.Fatalf("first tile = %+v, want %+v", got, want)
	}
	if got, want := referencePixel(t, image, 5, 0), (Color{R: 255, A: 255}); got != want {
		t.Fatalf("second tile = %+v, want %+v", got, want)
	}
	if got, want := referencePixel(t, image, 0, 2), (Color{R: 255, A: 255}); got != want {
		t.Fatalf("filled rectangle = %+v, want %+v", got, want)
	}
	if got, want := referencePixel(t, image, 4, 2), (Color{G: 255, A: 255}); got != want {
		t.Fatalf("stroked rectangle edge = %+v, want %+v", got, want)
	}
	if got := referencePixel(t, image, 4, 3); got.A != 0 {
		t.Fatalf("stroked rectangle center = %+v, want transparent", got)
	}
	if got, want := referencePixel(t, image, 1, 6), (Color{B: 255, A: 255}); got != want {
		t.Fatalf("filled circle = %+v, want %+v", got, want)
	}
	if got, want := referencePixel(t, image, 6, 6), white; got != want {
		t.Fatalf("stroked line = %+v, want %+v", got, want)
	}
	if !referenceRegionHasColor(image, 9, 0, 5, 13, white) {
		t.Fatal("basicfont text did not render")
	}
}

func TestReferenceBackendRendersStrokeCircle(t *testing.T) {
	backend := newReferenceBackend(t, 7, 7)
	white := Color{R: 255, G: 255, B: 255, A: 255}
	var queue Queue
	if err := queue.StrokeCircle(0, ScreenSpace, CircleDraw{Center: Vec2{X: 3.5, Y: 3.5}, Radius: 1.5, Width: 1, Color: white}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue}); err != nil {
		t.Fatal(err)
	}
	image := backend.Snapshot()
	if got, want := referencePixel(t, image, 3, 1), white; got != want {
		t.Fatalf("stroked circle outer edge = %+v, want %+v", got, want)
	}
	if got := referencePixel(t, image, 3, 3); got.A != 0 {
		t.Fatalf("stroked circle center = %+v, want transparent", got)
	}
}

func TestReferenceBackendAppliesWorldCameraTranslation(t *testing.T) {
	backend := newReferenceBackend(t, 4, 1)
	var queue Queue
	if err := queue.FillRect(0, WorldSpace, RectDraw{Bounds: Rect{X: 2, W: 1, H: 1}, Color: Color{R: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{X: 3, W: 1, H: 1}, Color: Color{G: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Camera: Camera{Position: Vec2{X: 2}}, Queue: &queue}); err != nil {
		t.Fatal(err)
	}
	if got, want := referencePixel(t, backend.Snapshot(), 0, 0), (Color{R: 255, A: 255}); got != want {
		t.Fatalf("world-space pixel = %+v, want %+v", got, want)
	}
	if got, want := referencePixel(t, backend.Snapshot(), 3, 0), (Color{G: 255, A: 255}); got != want {
		t.Fatalf("screen-space pixel = %+v, want %+v", got, want)
	}
}

func TestReferenceBackendCompositesStraightAlpha(t *testing.T) {
	backend := newReferenceBackend(t, 1, 1)
	backend.Reset(Color{B: 255, A: 255})
	var queue Queue
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}, Color: Color{R: 255, A: 128}}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue}); err != nil {
		t.Fatal(err)
	}
	if got, want := referencePixel(t, backend.Snapshot(), 0, 0), (Color{R: 128, B: 127, A: 255}); got != want {
		t.Fatalf("source-over pixel = %+v, want %+v", got, want)
	}
}

func TestReferenceBackendReportsInvalidTexture(t *testing.T) {
	backend := newReferenceBackend(t, 1, 1)
	var queue Queue
	if err := queue.DrawSprite(0, ScreenSpace, Sprite{Texture: Texture{ID: 1}, Bounds: Rect{W: 1, H: 1}, Tint: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}
	err := backend.Render(Frame{Queue: &queue, Textures: NewTextureStore()})
	if err == nil {
		t.Fatal("unregistered texture rendered")
	}
	var failure *diagnostics.Failure
	if !errors.As(err, &failure) {
		t.Fatalf("render error %v is not a diagnostics failure", err)
	}
	if failure.Subsystem != diagnostics.RendererSubsystem || failure.Operation != "render reference frame" || failure.Recovery != diagnostics.CorrectInput || failure.Terminal {
		t.Fatalf("failure = %+v", failure)
	}
}

func TestCompareImagesUsesExplicitTolerance(t *testing.T) {
	want := mustReferenceImage(t, 2, 1, []byte{1, 2, 3, 4, 5, 6, 7, 8})
	got := mustReferenceImage(t, 2, 1, []byte{1, 2, 3, 4, 7, 6, 7, 8})
	comparison, err := CompareImages(want, got, ImageTolerance{})
	if err != nil {
		t.Fatal(err)
	}
	if comparison.WithinTolerance || comparison.DifferentPixels != 1 || comparison.MaxChannelDifference != 2 || comparison.FirstDifferenceX != 1 || comparison.FirstDifferenceY != 0 {
		t.Fatalf("exact comparison = %+v", comparison)
	}
	comparison, err = CompareImages(want, got, ImageTolerance{PerChannel: 2})
	if err != nil {
		t.Fatal(err)
	}
	if !comparison.WithinTolerance || comparison.DifferentPixels != 0 {
		t.Fatalf("per-channel comparison = %+v", comparison)
	}
	if _, err := CompareImages(want, got, ImageTolerance{DifferentPixels: -1}); err == nil {
		t.Fatal("negative tolerance succeeded")
	}
}

func newReferenceBackend(t *testing.T, width, height int) *ReferenceBackend {
	t.Helper()
	backend, err := NewReferenceBackend(width, height)
	if err != nil {
		t.Fatal(err)
	}
	return backend
}

func mustReferenceImage(t *testing.T, width, height int, pixels []byte) Image {
	t.Helper()
	image, err := NewImage(width, height, pixels)
	if err != nil {
		t.Fatal(err)
	}
	return image
}

func referencePixel(t *testing.T, image Image, x, y int) Color {
	t.Helper()
	if x < 0 || y < 0 || x >= image.Width || y >= image.Height {
		t.Fatalf("pixel (%d,%d) outside %dx%d", x, y, image.Width, image.Height)
	}
	offset := (y*image.Width + x) * 4
	return Color{R: image.Pixels[offset], G: image.Pixels[offset+1], B: image.Pixels[offset+2], A: image.Pixels[offset+3]}
}

func referenceRegionHasColor(image Image, x, y, width, height int, want Color) bool {
	for row := y; row < y+height && row < image.Height; row++ {
		for column := x; column < x+width && column < image.Width; column++ {
			if referencePixelValue(image, column, row) == want {
				return true
			}
		}
	}
	return false
}

func referencePixelValue(image Image, x, y int) Color {
	offset := (y*image.Width + x) * 4
	return Color{R: image.Pixels[offset], G: image.Pixels[offset+1], B: image.Pixels[offset+2], A: image.Pixels[offset+3]}
}
