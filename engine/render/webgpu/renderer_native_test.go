//go:build !(js && wasm)

package webgpu

import (
	"testing"

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
}

func metricCounts(registry *diagnostics.Registry) map[string]uint64 {
	counts := make(map[string]uint64)
	for _, metric := range registry.Snapshot() {
		counts[metric.Name] = metric.Count
	}
	return counts
}
