package render

import "testing"

func TestQueueRecordsValidatedHighLevel2DCommands(t *testing.T) {
	var queue Queue
	queue.Clear(Color{A: 255})
	if err := queue.DrawSprite(3, WorldSpace, Sprite{Texture: Texture{ID: 1}, Bounds: Rect{W: 16, H: 16}, Tint: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}
	if err := queue.DrawText(10, ScreenSpace, TextDraw{Value: "HUD", Color: Color{A: 255}}); err != nil {
		t.Fatal(err)
	}
	commands := queue.Commands()
	if len(commands) != 3 || commands[0].Kind != Clear || commands[1].Layer != 3 || commands[2].Space != ScreenSpace {
		t.Fatalf("commands = %+v", commands)
	}
	if err := queue.FillCircle(0, Space(99), CircleDraw{Radius: 1}); err == nil {
		t.Fatal("invalid render space succeeded")
	}
}
