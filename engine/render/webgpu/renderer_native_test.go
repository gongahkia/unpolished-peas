//go:build !(js && wasm)

package webgpu

import (
	"errors"
	"testing"

	"github.com/gogpu/wgpu"
	"github.com/gongahkia/72/engine/diagnostics"
	"github.com/gongahkia/72/engine/render"
)

func TestHeadlessRendererSubmitsAnOrderedSpriteFrame(t *testing.T) {
	renderer, err := NewHeadless(16, 16)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 1, Height: 1, Pixels: []byte{255, 255, 255, 255}})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	queue := &render.Queue{}
	queue.Clear(render.Color{R: 3, G: 7, B: 11, A: 255})
	if err := queue.DrawSprite(2, render.ScreenSpace, render.Sprite{Texture: texture, Bounds: render.Rect{X: 1, Y: 1, W: 8, H: 8}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
		t.Fatalf("DrawSprite() error = %v", err)
	}
	if err := renderer.Render(render.Frame{Queue: queue, Textures: store}); err != nil {
		t.Fatalf("Render() error = %v", err)
	}
}

func TestHeadlessRendererRecordsAnOptionalTraceSpan(t *testing.T) {
	renderer, err := NewHeadless(2, 2)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	queue := &render.Queue{}
	if err := queue.FillRect(0, render.ScreenSpace, render.RectDraw{Bounds: render.Rect{W: 1, H: 1}, Color: render.Color{R: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	trace := diagnostics.NewTrace(1)
	if err := renderer.Render(render.Frame{Queue: queue, Trace: trace}); err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	spans, dropped := trace.Snapshot()
	if dropped != 0 || len(spans) != 1 || spans[0].Name != "renderer.webgpu.frame" {
		t.Fatalf("trace spans = %+v, dropped=%d", spans, dropped)
	}
}

func TestHeadlessRendererProducesOrderedSpriteAndTilePixels(t *testing.T) {
	renderer, err := NewHeadless(8, 4)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 2, Height: 1, Pixels: []byte{
		255, 0, 0, 255,
		0, 255, 0, 255,
	}})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	queue := &render.Queue{}
	queue.Clear(render.Color{R: 3, G: 7, B: 11, A: 255})
	if err := queue.DrawSprite(1, render.ScreenSpace, render.Sprite{Texture: texture, Source: render.Rect{W: 1, H: 1}, Bounds: render.Rect{X: 1, Y: 1, W: 2, H: 2}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
		t.Fatalf("DrawSprite(red) error = %v", err)
	}
	if err := queue.DrawSprite(1, render.ScreenSpace, render.Sprite{Texture: texture, Source: render.Rect{X: 1, W: 1, H: 1}, Bounds: render.Rect{X: 1, Y: 1, W: 2, H: 2}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
		t.Fatalf("DrawSprite(green) error = %v", err)
	}
	if err := queue.DrawTileMap(2, render.ScreenSpace, render.TileMap{
		Texture: texture, Atlas: render.Vec2{X: 2, Y: 1}, TileSize: render.Vec2{X: 1, Y: 1},
		Columns: 2, Tiles: []int{0, 1}, Bounds: render.Rect{X: 4, Y: 1}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255},
	}); err != nil {
		t.Fatalf("DrawTileMap() error = %v", err)
	}
	if err := renderer.Render(render.Frame{Queue: queue, Textures: store}); err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	pixels, err := renderer.surface.ReadPixels()
	if err != nil {
		t.Fatalf("ReadPixels() error = %v", err)
	}
	assertPixel(t, pixels, 8, 0, 0, render.Color{R: 3, G: 7, B: 11, A: 255})
	assertPixel(t, pixels, 8, 1, 1, render.Color{G: 255, A: 255})
	assertPixel(t, pixels, 8, 4, 1, render.Color{R: 255, A: 255})
	assertPixel(t, pixels, 8, 5, 1, render.Color{G: 255, A: 255})
}

func TestBatchesInstanceCompatibleSpritesAndTiles(t *testing.T) {
	renderer, err := NewHeadless(8, 4)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 2, Height: 1, Pixels: []byte{
		255, 0, 0, 255,
		0, 255, 0, 255,
	}})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	queue := &render.Queue{}
	for _, x := range []float64{0, 2} {
		if err := queue.DrawSprite(1, render.ScreenSpace, render.Sprite{Texture: texture, Bounds: render.Rect{X: x, W: 1, H: 1}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
			t.Fatalf("DrawSprite() error = %v", err)
		}
	}
	if err := queue.DrawTileMap(2, render.ScreenSpace, render.TileMap{
		Texture: texture, Atlas: render.Vec2{X: 2, Y: 1}, TileSize: render.Vec2{X: 1, Y: 1}, Columns: 2,
		Tiles: []int{0, 1}, Bounds: render.Rect{X: 4}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255},
	}); err != nil {
		t.Fatalf("DrawTileMap() error = %v", err)
	}
	batches, err := renderer.batches(render.Frame{Queue: queue, Textures: store}, orderedCommands(queue.Commands()), 8, 4)
	if err != nil {
		t.Fatalf("batches() error = %v", err)
	}
	if len(batches) != 1 || batches[0].kind != spriteInstanceBatch || len(batches[0].instances) != 4 || len(batches[0].vertices) != 0 {
		t.Fatalf("batches = %+v, want one four-instance sprite batch", batches)
	}
}

func TestHeadlessRendererRecreatesItsDeviceAndRehydratesPortableTextures(t *testing.T) {
	renderer, err := NewHeadless(4, 4)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 1, Height: 1, Pixels: []byte{255, 0, 0, 255}})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	queue := &render.Queue{}
	queue.Clear(render.Color{A: 255})
	if err := queue.DrawSprite(1, render.ScreenSpace, render.Sprite{Texture: texture, Bounds: render.Rect{X: 1, Y: 1, W: 2, H: 2}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
		t.Fatalf("DrawSprite() error = %v", err)
	}
	frame := render.Frame{Queue: queue, Textures: store}
	if err := renderer.Render(frame); err != nil {
		t.Fatalf("initial Render() error = %v", err)
	}
	if handled, err := renderer.recoverPresentation(wgpu.ErrDeviceLost); !handled || err != nil {
		t.Fatalf("recoverPresentation(device lost) = handled=%t err=%v", handled, err)
	}
	if err := renderer.Render(frame); err != nil {
		t.Fatalf("Render() after recreation error = %v", err)
	}
	pixels, err := renderer.surface.ReadPixels()
	if err != nil {
		t.Fatalf("ReadPixels() after recreation error = %v", err)
	}
	assertPixel(t, pixels, 4, 1, 1, render.Color{R: 255, A: 255})
}

func TestHeadlessRendererRefreshesAndPrunesTextureResources(t *testing.T) {
	renderer, err := NewHeadless(2, 2)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 1, Height: 1, Pixels: []byte{255, 0, 0, 255}})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	queue := &render.Queue{}
	queue.Clear(render.Color{A: 255})
	if err := queue.DrawSprite(1, render.ScreenSpace, render.Sprite{Texture: texture, Bounds: render.Rect{W: 2, H: 2}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
		t.Fatalf("DrawSprite() error = %v", err)
	}
	frame := render.Frame{Queue: queue, Textures: store}
	if err := renderer.Render(frame); err != nil {
		t.Fatalf("initial Render() error = %v", err)
	}
	first := renderer.textures[texture.ID]
	if first == nil || first.revision != 1 {
		t.Fatalf("initial native texture = %+v", first)
	}
	instanceBuffer, instanceBufferSize := renderer.spriteInstanceBuffer, renderer.spriteInstanceBufferSize
	if instanceBuffer == nil || instanceBufferSize == 0 {
		t.Fatal("initial render did not allocate an instance buffer")
	}
	if err := store.Replace(texture, render.Image{Width: 1, Height: 1, Pixels: []byte{0, 255, 0, 255}}); err != nil {
		t.Fatalf("Replace() error = %v", err)
	}
	if err := renderer.Render(frame); err != nil {
		t.Fatalf("Render() after replacement error = %v", err)
	}
	second := renderer.textures[texture.ID]
	if second == nil || second == first || second.revision != 2 {
		t.Fatalf("refreshed native texture = %+v, want a new revision-2 resource", second)
	}
	if renderer.spriteInstanceBuffer != instanceBuffer || renderer.spriteInstanceBufferSize != instanceBufferSize {
		t.Fatal("unchanged instance workload did not reuse the dynamic buffer")
	}
	pixels, err := renderer.surface.ReadPixels()
	if err != nil {
		t.Fatalf("ReadPixels() after replacement error = %v", err)
	}
	assertPixel(t, pixels, 2, 0, 0, render.Color{G: 255, A: 255})
	if !store.Release(texture) {
		t.Fatal("Release() returned false")
	}
	if err := renderer.Render(frame); err == nil {
		t.Fatal("Render() with a released texture succeeded")
	}
	if _, cached := renderer.textures[texture.ID]; cached {
		t.Fatal("released texture remained in the native cache")
	}
}

func TestPresentationFaultClassification(t *testing.T) {
	if !presentationFault(wgpu.ErrTimeout) || !presentationFault(wgpu.ErrSurfaceOutdated) || !presentationFault(wgpu.ErrSurfaceLost) || !presentationFault(wgpu.ErrDeviceLost) {
		t.Fatal("known WebGPU presentation fault was not classified as recoverable")
	}
	if presentationFault(wgpu.ErrOutOfMemory) {
		t.Fatal("out-of-memory was classified as recoverable")
	}
	if err := presentationFailure("present", wgpu.ErrOutOfMemory); !errors.Is(err, wgpu.ErrOutOfMemory) {
		t.Fatalf("out-of-memory failure did not preserve the cause: %v", err)
	}
}

func TestHeadlessRendererSubmitsTilePrimitiveAndTextCommands(t *testing.T) {
	renderer, err := NewHeadless(32, 32)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 2, Height: 2, Pixels: []byte{
		255, 0, 0, 255, 0, 255, 0, 255,
		0, 0, 255, 255, 255, 255, 255, 255,
	}})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	queue := &render.Queue{}
	if err := queue.DrawTileMap(1, render.ScreenSpace, render.TileMap{
		Texture: texture, Atlas: render.Vec2{X: 2, Y: 2}, TileSize: render.Vec2{X: 1, Y: 1},
		Columns: 2, Tiles: []int{0, 1, 2, 3}, Bounds: render.Rect{X: 1, Y: 1}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255},
	}); err != nil {
		t.Fatalf("DrawTileMap() error = %v", err)
	}
	if err := queue.FillCircle(2, render.ScreenSpace, render.CircleDraw{Center: render.Vec2{X: 16, Y: 16}, Radius: 4, Color: render.Color{R: 255, A: 255}}); err != nil {
		t.Fatalf("FillCircle() error = %v", err)
	}
	if err := queue.DrawText(3, render.ScreenSpace, render.TextDraw{Position: render.Vec2{X: 1, Y: 30}, Value: "72", Color: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
		t.Fatalf("DrawText() error = %v", err)
	}
	if err := renderer.Render(render.Frame{Queue: queue, Textures: store}); err != nil {
		t.Fatalf("Render() error = %v", err)
	}
}

func TestHeadlessRendererReportsSubmittedBatchMetrics(t *testing.T) {
	renderer, err := NewHeadless(16, 16)
	if err != nil {
		t.Fatalf("NewHeadless() error = %v", err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 1, Height: 1, Pixels: []byte{255, 255, 255, 255}})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	queue := &render.Queue{}
	for _, x := range []float64{1, 9} {
		if err := queue.DrawSprite(1, render.ScreenSpace, render.Sprite{Texture: texture, Bounds: render.Rect{X: x, Y: 1, W: 6, H: 6}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
			t.Fatalf("DrawSprite() error = %v", err)
		}
	}
	if err := queue.FillRect(2, render.ScreenSpace, render.RectDraw{Bounds: render.Rect{X: 1, Y: 9, W: 6, H: 6}, Color: render.Color{G: 255, A: 255}}); err != nil {
		t.Fatalf("FillRect() error = %v", err)
	}
	metrics := diagnostics.NewRegistry()
	if err := renderer.Render(render.Frame{Queue: queue, Textures: store, Diagnostics: metrics}); err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	got := metricCounts(metrics)
	if got["renderer.batches"] != 2 || got["renderer.draw_calls"] != 2 {
		t.Fatalf("submitted batch metrics = batches=%d draw_calls=%d, want 2 and 2", got["renderer.batches"], got["renderer.draw_calls"])
	}
	if got["renderer.texture_uploads"] != 1 {
		t.Fatalf("texture uploads = %d, want 1", got["renderer.texture_uploads"])
	}
	if got["renderer.native_pipeline_entries"] != 2 {
		t.Fatalf("native pipeline entries = %d, want 2", got["renderer.native_pipeline_entries"])
	}
	if got["renderer.native_buffer_bytes"] == 0 {
		t.Fatal("native buffer capacity metric was not recorded")
	}
}

func metricCounts(registry *diagnostics.Registry) map[string]uint64 {
	counts := make(map[string]uint64)
	for _, metric := range registry.Snapshot() {
		counts[metric.Name] = metric.Count
	}
	return counts
}

func assertPixel(t *testing.T, pixels []byte, width, x, y int, want render.Color) {
	t.Helper()
	offset := (y*width + x) * 4
	got := render.Color{R: pixels[offset], G: pixels[offset+1], B: pixels[offset+2], A: pixels[offset+3]}
	if got != want {
		t.Fatalf("pixel (%d,%d) = %#v, want %#v", x, y, got, want)
	}
}

func BenchmarkHeadlessTileMapScene(b *testing.B) {
	renderer, err := NewHeadless(320, 180)
	if err != nil {
		b.Fatal(err)
	}
	defer renderer.Close()
	store := render.NewTextureStore()
	texture, err := store.Create(render.Image{Width: 16, Height: 16, Pixels: benchmarkTexturePixels(16, 16)})
	if err != nil {
		b.Fatal(err)
	}
	tiles := make([]int, 40*22)
	for index := range tiles {
		tiles[index] = index % 4
	}
	queue := &render.Queue{}
	queue.Clear(render.Color{R: 8, G: 10, B: 15, A: 255})
	if err := queue.DrawTileMap(0, render.ScreenSpace, render.TileMap{
		Texture: texture, Atlas: render.Vec2{X: 16, Y: 16}, TileSize: render.Vec2{X: 8, Y: 8}, Columns: 40,
		Tiles: tiles, Bounds: render.Rect{W: 320, H: 176}, Tint: render.Color{R: 255, G: 255, B: 255, A: 255},
	}); err != nil {
		b.Fatal(err)
	}
	metrics := diagnostics.NewRegistry()
	frame := render.Frame{Queue: queue, Textures: store, Diagnostics: metrics}
	if err := renderer.Render(frame); err != nil {
		b.Fatal(err)
	}
	recorded := metricCounts(metrics)
	frame.Diagnostics = nil
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if err := renderer.Render(frame); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(recorded["renderer.visible_tiles"]), "visible-tiles/op")
	b.ReportMetric(float64(recorded["renderer.batches"]), "batches/op")
	b.ReportMetric(float64(recorded["renderer.draw_calls"]), "draw-calls/op")
}

func benchmarkTexturePixels(width, height int) []byte {
	pixels := make([]byte, width*height*4)
	for y := range height {
		for x := range width {
			offset := (y*width + x) * 4
			pixels[offset] = uint8(64 + x*9)
			pixels[offset+1] = uint8(96 + y*7)
			pixels[offset+2], pixels[offset+3] = 180, 255
		}
	}
	return pixels
}
