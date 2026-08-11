package render

import (
	"math"
	"testing"
)

func TestQueueRecordsValidatedHighLevel2DCommands(t *testing.T) {
	var queue Queue
	queue.Clear(Color{A: 255})
	if err := queue.DrawSprite(3, WorldSpace, Sprite{Texture: Texture{ID: 1}, Bounds: Rect{W: 16, H: 16}, Tint: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.DrawText(10, ScreenSpace, TextDraw{Value: "HUD", Color: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.StrokeCircle(11, ScreenSpace, CircleDraw{Radius: 2, Width: 1, Color: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}
	commands := queue.Commands()
	if len(commands) != 4 || commands[0].Kind != Clear || commands[1].Layer != 3 || commands[2].Space != ScreenSpace || commands[3].Kind != StrokeCircle {
		t.Fatalf("commands = %+v", commands)
	}
	if err := queue.FillCircle(0, Space(99), CircleDraw{Radius: 1}); err == nil {
		t.Fatal("invalid render space succeeded")
	}
	if err := queue.StrokeCircle(0, ScreenSpace, CircleDraw{Radius: 1}); err == nil {
		t.Fatal("zero stroked-circle width succeeded")
	}
	if err := queue.DrawSprite(0, ScreenSpace, Sprite{Texture: Texture{ID: 1}, Bounds: Rect{W: 1, H: 1}, Transform: SpriteTransform{Rotation: math.NaN()}}); err == nil {
		t.Fatal("non-finite sprite transform succeeded")
	}
}

func TestQueueResolvesNestedScreenSpaceClipsWhenRecordingDraws(t *testing.T) {
	var queue Queue
	if err := queue.PushClip(Rect{X: 1, Y: 2, W: 5, H: 5}); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.PushClip(Rect{X: 4, Y: 4, W: 5, H: 5}); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.PopClip(); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.PopClip(); err != nil {
		t.Fatal(err)
	}
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}}); err != nil {
		t.Fatal(err)
	}
	commands := queue.Commands()
	for index, want := range []*Rect{{X: 1, Y: 2, W: 5, H: 5}, {X: 4, Y: 4, W: 2, H: 3}, {X: 1, Y: 2, W: 5, H: 5}, nil} {
		got, ok := commands[index].Clip()
		if ok != (want != nil) {
			t.Fatalf("command %d clip = %+v, %t, want %+v", index, got, ok, want)
		}
		if want != nil && got != *want {
			t.Fatalf("command %d clip = %+v, want %+v", index, got, *want)
		}
	}
	if err := queue.PopClip(); err == nil {
		t.Fatal("empty clip stack pop succeeded")
	}
	if err := queue.PushClip(Rect{W: 1, H: 1}); err != nil {
		t.Fatal(err)
	}
	queue.Reset()
	if err := queue.FillRect(0, ScreenSpace, RectDraw{Bounds: Rect{W: 1, H: 1}}); err != nil {
		t.Fatal(err)
	}
	if _, ok := queue.Commands()[0].Clip(); ok {
		t.Fatal("reset retained a clip")
	}
}

func TestTileMapVisibleRangeKeepsPartialAndEdgeTiles(t *testing.T) {
	tiles := TileMap{Columns: 3, Tiles: make([]int, 6), TileSize: Vec2{X: 1, Y: 1}}
	for _, test := range []struct {
		viewport Rect
		want     TileRange
	}{
		{viewport: Rect{X: .25, Y: .25, W: 1, H: 1}, want: TileRange{Column: 0, Row: 0, Columns: 2, Rows: 2}},
		{viewport: Rect{X: 1, Y: 0, W: 2, H: 1}, want: TileRange{Column: 1, Row: 0, Columns: 2, Rows: 1}},
		{viewport: Rect{X: 2, Y: 1, W: 1, H: 1}, want: TileRange{Column: 2, Row: 1, Columns: 1, Rows: 1}},
		{viewport: Rect{X: 3, Y: 0, W: 1, H: 1}, want: TileRange{}},
	} {
		if got := tiles.VisibleRange(test.viewport); got != test.want {
			t.Fatalf("visible range for %+v = %+v, want %+v", test.viewport, got, test.want)
		}
	}
}
