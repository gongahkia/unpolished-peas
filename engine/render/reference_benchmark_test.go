package render

import "testing"

func BenchmarkReferenceSpriteScene(b *testing.B) {
	store := NewTextureStore()
	texture, err := store.Create(benchmarkImage(8, 8))
	if err != nil {
		b.Fatal(err)
	}
	var queue Queue
	queue.Clear(Color{R: 8, G: 10, B: 15, A: 255})
	for index := range 160 {
		if err := queue.DrawSprite(index%8, WorldSpace, Sprite{
			Texture: texture,
			Bounds:  Rect{X: float64(index%20) * 16, Y: float64(index/20) * 16, W: 12, H: 12},
			Tint:    Color{R: 255, G: 255, B: 255, A: 255},
		}); err != nil {
			b.Fatal(err)
		}
	}
	benchmarkReferenceFrame(b, Frame{Camera: Camera{Position: Vec2{X: 12, Y: 8}}, Queue: &queue, Textures: store})
}

func BenchmarkReferenceTileMapScene(b *testing.B) {
	store := NewTextureStore()
	texture, err := store.Create(benchmarkImage(16, 16))
	if err != nil {
		b.Fatal(err)
	}
	tiles := make([]int, 40*22)
	for index := range tiles {
		tiles[index] = index % 4
	}
	var queue Queue
	queue.Clear(Color{R: 8, G: 10, B: 15, A: 255})
	if err := queue.DrawTileMap(0, WorldSpace, TileMap{
		Texture: texture, Atlas: Vec2{X: 16, Y: 16}, TileSize: Vec2{X: 8, Y: 8}, Columns: 40,
		Tiles: tiles, Bounds: Rect{W: 320, H: 176}, Tint: Color{R: 255, G: 255, B: 255, A: 255},
	}); err != nil {
		b.Fatal(err)
	}
	benchmarkReferenceFrame(b, Frame{Camera: Camera{Position: Vec2{X: 8, Y: 4}}, Queue: &queue, Textures: store})
}

func BenchmarkReferencePrimitiveScene(b *testing.B) {
	var queue Queue
	queue.Clear(Color{R: 8, G: 10, B: 15, A: 255})
	for index := range 96 {
		color := Color{R: uint8(32 + index%4*40), G: 120, B: 180, A: 192}
		if err := queue.FillRect(index%6, ScreenSpace, RectDraw{Bounds: Rect{X: float64(index%16) * 20, Y: float64(index/16) * 20, W: 12, H: 12}, Color: color}); err != nil {
			b.Fatal(err)
		}
		if err := queue.StrokeLine(index%6, ScreenSpace, LineDraw{Start: Vec2{X: float64(index%16) * 20, Y: float64(index/16)*20 + 14}, End: Vec2{X: float64(index%16)*20 + 12, Y: float64(index/16)*20 + 18}, Width: 1, Color: color}); err != nil {
			b.Fatal(err)
		}
	}
	for index := range 24 {
		if err := queue.FillCircle(7, ScreenSpace, CircleDraw{Center: Vec2{X: float64(index%12)*26 + 8, Y: float64(index/12)*80 + 150}, Radius: 6, Color: Color{R: 244, G: 183, B: 116, A: 200}}); err != nil {
			b.Fatal(err)
		}
	}
	benchmarkReferenceFrame(b, Frame{Queue: &queue})
}

func BenchmarkReferenceTextScene(b *testing.B) {
	var queue Queue
	queue.Clear(Color{R: 8, G: 10, B: 15, A: 255})
	for index := range 32 {
		if err := queue.DrawText(index%4, ScreenSpace, TextDraw{Position: Vec2{X: 8, Y: float64(14 + index*10)}, Value: "72 reference benchmark", Color: Color{R: 229, G: 233, B: 240, A: 255}}); err != nil {
			b.Fatal(err)
		}
	}
	benchmarkReferenceFrame(b, Frame{Queue: &queue})
}

func benchmarkReferenceFrame(b *testing.B, frame Frame) {
	b.Helper()
	backend, err := NewReferenceBackend(320, 180)
	if err != nil {
		b.Fatal(err)
	}
	metrics := CollectFrameMetrics(frame, Rect{W: 320, H: 180})
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if err := backend.Render(frame); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(metrics.Commands), "commands/op")
	b.ReportMetric(float64(metrics.CompatibleSpriteRuns), "sprite-runs/op")
	b.ReportMetric(float64(metrics.TileCells), "tile-cells/op")
	b.ReportMetric(float64(metrics.VisibleTiles), "visible-tiles/op")
}

func benchmarkImage(width, height int) Image {
	pixels := make([]byte, width*height*4)
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			offset := (y*width + x) * 4
			pixels[offset] = uint8(64 + x*9)
			pixels[offset+1] = uint8(96 + y*7)
			pixels[offset+2] = 180
			pixels[offset+3] = 255
		}
	}
	return Image{Width: width, Height: height, Pixels: pixels}
}
