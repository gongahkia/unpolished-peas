package render

import (
	"testing"

	"github.com/gongahkia/72/engine/diagnostics"
)

func TestCollectFrameMetricsReportsCommandAndVisibleTileCounts(t *testing.T) {
	store := NewTextureStore()
	texture, err := store.Create(Image{Width: 1, Height: 1, Pixels: []byte{255, 255, 255, 255}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateRenderTarget(1, 1); err != nil {
		t.Fatal(err)
	}
	var queue Queue
	queue.Clear(Color{})
	for index := range 2 {
		if err := queue.DrawSprite(0, ScreenSpace, Sprite{Texture: texture, Bounds: Rect{X: float64(index), W: 1, H: 1}, Tint: Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
			t.Fatal(err)
		}
	}
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}, Color: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.DrawTileMap(0, WorldSpace, TileMap{Texture: texture, Atlas: Vec2{X: 1, Y: 1}, TileSize: Vec2{X: 1, Y: 1}, Columns: 4, Tiles: []int{0, -1, 0, 0}, Tint: Color{R: 255, G: 255, B: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.DrawText(0, ScreenSpace, TextDraw{Value: "A", Color: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}

	metrics := CollectFrameMetrics(Frame{Camera: Camera{Position: Vec2{X: 1}}, Queue: &queue, Textures: store}, Rect{W: 2, H: 1})
	want := FrameMetrics{
		Commands: 6, ClearCommands: 1, Sprites: 2, TileMaps: 1, Primitives: 1, Texts: 1,
		TileCells: 3, VisibleTiles: 1, CompatibleSpriteRuns: 1,
		PortableTextures: 2, PortableTextureBytes: 8, RenderTargets: 1, RenderTargetBytes: 4,
	}
	if metrics != want {
		t.Fatalf("frame metrics = %+v, want %+v", metrics, want)
	}
}

func TestReferenceBackendRecordsFrameMetricsIntoDiagnostics(t *testing.T) {
	backend := newReferenceBackend(t, 1, 1)
	registry := diagnostics.NewRegistry()
	var queue Queue
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}, Color: Color{R: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue, Diagnostics: registry}); err != nil {
		t.Fatal(err)
	}
	metrics := metricsByName(registry.Snapshot())
	if got := metrics["renderer.frames"].Count; got != 1 {
		t.Fatalf("renderer frames = %d, want 1", got)
	}
	if got := metrics["renderer.commands"].Count; got != 1 {
		t.Fatalf("renderer commands = %d, want 1", got)
	}
	if got := metrics["renderer.primitive_commands"].Count; got != 1 {
		t.Fatalf("renderer primitives = %d, want 1", got)
	}
	if metric := metrics["renderer.frame_time"]; metric.Count != 1 || metric.Total < 0 {
		t.Fatalf("renderer frame time = %+v", metric)
	}
}

func TestReferenceBackendRecordsAnOptionalTraceSpan(t *testing.T) {
	backend := newReferenceBackend(t, 1, 1)
	trace := diagnostics.NewTrace(1)
	var queue Queue
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}, Color: Color{R: 255, A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := backend.Render(Frame{Queue: &queue, Trace: trace}); err != nil {
		t.Fatal(err)
	}
	spans, dropped := trace.Snapshot()
	if dropped != 0 || len(spans) != 1 || spans[0].Name != "renderer.reference.frame" {
		t.Fatalf("trace spans = %+v, dropped=%d", spans, dropped)
	}
}

func metricsByName(metrics []diagnostics.Metric) map[string]diagnostics.Metric {
	byName := make(map[string]diagnostics.Metric, len(metrics))
	for _, metric := range metrics {
		byName[metric.Name] = metric
	}
	return byName
}
