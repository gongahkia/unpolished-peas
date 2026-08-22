package main

import (
	"testing"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/ecs"
	"github.com/gongahkia/72/engine/render"
)

func TestFirstGameMovesECSPlayerAndEmitsCommandFrames(t *testing.T) {
	game := &firstGame{}
	runtime, err := engine.NewRuntime(engine.Config{
		Viewport:    engine.Size{W: 320, H: 180},
		WindowScale: 1,
		Actions:     engine.ActionMap{actionMove: {Axis: &engine.AxisBinding{Positive: []engine.Key{engine.KeyD}}}},
	}, game)
	if err != nil {
		t.Fatalf("new runtime: %v", err)
	}
	if err := runtime.Update(engine.NewInput(map[engine.Action]engine.ActionState{actionMove: {Down: true, Value: 1}})); err != nil {
		t.Fatalf("update: %v", err)
	}
	position, ok := ecs.Get[playerPosition](runtime.World(), game.player)
	if !ok || position.X != 153 || position.Y != 90 {
		t.Fatalf("player position = %+v, present=%t", position, ok)
	}
	backend := &recordingRenderBackend{}
	if err := runtime.Draw(backend); err != nil {
		t.Fatalf("draw: %v", err)
	}
	if len(backend.frames) != 2 {
		t.Fatalf("command frames = %d, want 2", len(backend.frames))
	}
	commands := backend.frames[1].Queue.Commands()
	if len(commands) != 2 || commands[0].Kind != render.FillRect || commands[1].Kind != render.Text {
		t.Fatalf("player commands = %+v", commands)
	}
}

type recordingRenderBackend struct{ frames []render.Frame }

func (b *recordingRenderBackend) Render(frame render.Frame) error {
	b.frames = append(b.frames, frame)
	return nil
}
