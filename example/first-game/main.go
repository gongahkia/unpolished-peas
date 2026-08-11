// Command first-game is the runnable companion to docs/FIRST_GAME.md.
//
// Game code below uses engine, engine/ecs, and engine/render. The final Run
// call uses the temporary Ebitengine host adapter until supported native and
// browser hosts are available; see the tutorial for that boundary.
package main

import (
	"fmt"
	"log"

	"github.com/gongahkia/72/engine"
	engineebiten "github.com/gongahkia/72/engine/ebiten"
	"github.com/gongahkia/72/engine/ecs"
	"github.com/gongahkia/72/engine/render"
)

const (
	actionMove engine.Action = "move"
	actionJump engine.Action = "jump"
)

type playerPosition struct{ X, Y float64 }

type firstGame struct {
	player  ecs.Entity
	runtime *engine.Runtime
}

func (g *firstGame) Initialize(runtime *engine.Runtime) error {
	g.runtime = runtime
	g.player = runtime.World().Spawn()
	if err := ecs.Add(runtime.World(), g.player, playerPosition{X: 150, Y: 90}); err != nil {
		return err
	}
	if err := runtime.Layers().Add(engine.Layer{
		ID:    "background",
		Order: 0,
		Space: engine.ScreenSpace,
		DrawCommands: func(frame engine.CommandFrame) error {
			return frame.Clear(render.Color{R: 18, G: 27, B: 46, A: 255})
		},
	}); err != nil {
		return err
	}
	return runtime.Layers().Add(engine.Layer{
		ID:    "player",
		Order: 1,
		Space: engine.ScreenSpace,
		DrawCommands: func(frame engine.CommandFrame) error {
			position, ok := ecs.Get[playerPosition](g.runtime.World(), g.player)
			if !ok {
				return fmt.Errorf("player entity lost its position component")
			}
			if err := frame.FillRect(render.RectDraw{
				Bounds: render.Rect{X: position.X, Y: position.Y, W: 18, H: 18},
				Color:  render.Color{R: 94, G: 230, B: 160, A: 255},
			}); err != nil {
				return err
			}
			return frame.DrawText(render.TextDraw{
				Position: render.Vec2{X: 10, Y: 18},
				Value:    "A/D or arrows move · space jumps",
				Color:    render.Color{R: 235, G: 242, B: 255, A: 255},
			})
		},
	})
}

func (g *firstGame) Update(input engine.Input) error {
	position, ok := ecs.Get[playerPosition](g.runtime.World(), g.player)
	if !ok {
		return fmt.Errorf("player entity lost its position component")
	}
	position.X += input.Axis(actionMove) * 3
	if input.Pressed(actionJump) {
		position.Y = 50
	} else if position.Y < 90 {
		position.Y++
	}
	return ecs.Set(g.runtime.World(), g.player, position)
}

func main() {
	config := engine.Config{
		Title:       "72 first game",
		Viewport:    engine.Size{W: 320, H: 180},
		WindowScale: 3,
		Actions: engine.ActionMap{
			actionMove: {Axis: &engine.AxisBinding{Negative: []engine.Key{engine.KeyA, engine.KeyArrowLeft}, Positive: []engine.Key{engine.KeyD, engine.KeyArrowRight}}},
			actionJump: {Keys: []engine.Key{engine.KeySpace}},
		},
	}
	if err := engineebiten.Run(config, &firstGame{}); err != nil {
		log.Fatal(err)
	}
}
