package main

import (
	"flag"
	"fmt"
	"log"
	"math"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/platform"
	"github.com/gongahkia/72/engine/render"
	"github.com/gongahkia/72/example/wukong/internal/sim"
)

const (
	logicalW = sim.ViewportW
	logicalH = sim.ViewportH
)

const (
	actionMove          engine.Action = "move"
	actionAimX          engine.Action = "aim-x"
	actionAimY          engine.Action = "aim-y"
	actionJump          engine.Action = "jump"
	actionDown          engine.Action = "down"
	actionRoll          engine.Action = "roll"
	actionInteract      engine.Action = "interact"
	actionThrow         engine.Action = "throw"
	actionDebug         engine.Action = "debug"
	actionRestart       engine.Action = "restart"
	actionNewSeed       engine.Action = "new-seed"
	actionPause         engine.Action = "pause"
	actionStep          engine.Action = "step"
	actionReplay        engine.Action = "save-replay"
	actionResultRestart engine.Action = "restart-after-result"
)

type wukongGame struct {
	world    *sim.World
	replay   *sim.Replay
	runtime  *engine.Runtime
	snapshot sim.RenderSnapshot
	seed     uint64
	nextSeed uint64
	paused   bool
	status   string
}

func (g *wukongGame) Initialize(runtime *engine.Runtime) error {
	g.runtime = runtime
	g.seed, g.nextSeed = runSeed(0x72, 0), 1
	if err := g.addLayers(); err != nil {
		return err
	}
	g.resetSameSeed()
	return nil
}

func (g *wukongGame) addLayers() error {
	layers := []engine.Layer{
		{ID: "clear", Order: -300, Space: engine.ScreenSpace, DrawCommands: func(frame engine.CommandFrame) error { return frame.Clear(render.Color{R: 8, G: 10, B: 15, A: 255}) }},
		{ID: "environment.deep", Order: -200, Space: engine.WorldSpace, Parallax: deepBackgroundDepth, DrawCommands: g.drawDeepBackgroundCommands},
		{ID: "environment.distant", Order: -100, Space: engine.WorldSpace, Parallax: backgroundDepth, DrawCommands: g.drawBackgroundCommands},
		{ID: "world", Order: 0, Space: engine.WorldSpace, Parallax: 1, DrawCommands: g.drawWorldCommands},
		{ID: "environment.foreground", Order: 100, Space: engine.ScreenSpace, DrawCommands: g.drawForegroundCommands},
		{ID: "hud", Order: 200, Space: engine.ScreenSpace, DrawCommands: g.drawHUDCommands},
		{ID: "debug", Order: 300, Space: engine.ScreenSpace, DrawCommands: g.drawDebugCommands},
	}
	for _, layer := range layers {
		if err := g.runtime.Layers().Add(layer); err != nil {
			return err
		}
	}
	return nil
}

func (g *wukongGame) resetSameSeed() {
	g.world = sim.NewRunWorld(g.seed)
	g.replay = sim.NewReplay(g.seed)
	g.refreshPresentation()
}

func (g *wukongGame) resetNextSeed() {
	g.seed = runSeed(0x72, g.nextSeed)
	g.nextSeed++
	g.resetSameSeed()
}

func runSeed(base, index uint64) uint64 {
	seed := base + index*0x9e3779b97f4a7c15
	seed ^= seed >> 30
	seed *= 0xbf58476d1ce4e5b9
	seed ^= seed >> 27
	seed *= 0x94d049bb133111eb
	seed ^= seed >> 31
	if seed == 0 {
		return 1
	}
	return seed
}

func (g *wukongGame) Update(input engine.Input) error {
	defer g.refreshPresentation()
	if input.Pressed(actionRestart) {
		g.resetSameSeed()
		g.status = fmt.Sprintf("restarted seed %x", g.seed)
		return nil
	}
	if input.Pressed(actionNewSeed) {
		g.resetNextSeed()
		g.status = fmt.Sprintf("new seed %x", g.seed)
		return nil
	}
	if input.Pressed(actionPause) {
		g.paused = !g.paused
	}
	if input.Pressed(actionReplay) {
		if err := sim.SaveReplay("wukong.replay.json", g.replay); err != nil {
			g.status = err.Error()
		} else {
			g.status = "saved wukong.replay.json"
		}
	}
	if (g.world.Lost || g.world.Won) && input.Pressed(actionResultRestart) {
		g.resetSameSeed()
		return nil
	}
	if g.paused && !input.Pressed(actionStep) {
		return nil
	}
	g.replay.Record(g.world, readInput(input))
	return nil
}

func (g *wukongGame) refreshPresentation() {
	g.snapshot = g.world.Snapshot()
	camera := followCamera(g.snapshot.Player.Pos)
	shake := g.snapshot.Trauma * 6
	g.runtime.Camera().SetPosition(engine.Vec2{X: camera.X, Y: camera.Y})
	g.runtime.Camera().SetOffset(engine.Vec2{
		X: math.Sin(float64(g.snapshot.Tick)*1.9) * shake,
		Y: math.Cos(float64(g.snapshot.Tick)*2.3) * shake,
	})
}

func readInput(input engine.Input) sim.InputFrame {
	return sim.InputFrame{
		MoveX:     axis(input.Axis(actionMove)),
		Jump:      input.Down(actionJump),
		Down:      input.Axis(actionDown) > .35,
		AimX:      axis(input.Axis(actionAimX)),
		AimY:      axis(input.Axis(actionAimY)),
		Roll:      input.Down(actionRoll),
		Interact:  input.Down(actionInteract),
		Throw:     input.Down(actionThrow),
		DebugStep: input.Down(actionDebug),
	}
}

func axis(value float64) int8 {
	if value > .35 {
		return 1
	}
	if value < -.35 {
		return -1
	}
	return 0
}

func actionMap() engine.ActionMap {
	button := func(keys []engine.Key, buttons ...engine.GamepadButton) engine.Binding {
		return engine.Binding{Keys: keys, GamepadButtons: buttons}
	}
	axis := func(negative, positive []engine.Key, gamepadAxis engine.GamepadAxis) engine.Binding {
		return engine.Binding{Axis: &engine.AxisBinding{Negative: negative, Positive: positive, GamepadAxis: gamepadAxis, UseGamepad: true, Deadzone: .35}}
	}
	return engine.ActionMap{
		actionMove:          axis([]engine.Key{engine.KeyA}, []engine.Key{engine.KeyD}, 0),
		actionAimX:          axis([]engine.Key{engine.KeyArrowLeft}, []engine.Key{engine.KeyArrowRight}, 2),
		actionAimY:          axis([]engine.Key{engine.KeyArrowUp}, []engine.Key{engine.KeyArrowDown}, 3),
		actionJump:          button([]engine.Key{engine.KeyW, engine.KeySpace}, 0),
		actionDown:          axis(nil, []engine.Key{engine.KeyS}, 1),
		actionRoll:          button([]engine.Key{engine.KeyShift}, 1),
		actionInteract:      button([]engine.Key{engine.KeyE}, 2),
		actionThrow:         button([]engine.Key{engine.KeyJ}, 3),
		actionDebug:         button([]engine.Key{engine.KeyTab}),
		actionRestart:       button([]engine.Key{engine.KeyF1}),
		actionNewSeed:       button([]engine.Key{engine.KeyF2}),
		actionPause:         button([]engine.Key{engine.KeyP}),
		actionStep:          button([]engine.Key{engine.KeyPeriod}),
		actionReplay:        button([]engine.Key{engine.KeyF6}),
		actionResultRestart: button([]engine.Key{engine.KeyEnter}),
	}
}

func main() {
	mode := flag.String("mode", "playtest", "playtest mode")
	flag.Parse()
	if *mode != "playtest" {
		log.Fatalf("unsupported mode %q; use playtest", *mode)
	}
	config := engine.Config{
		Title:       "Wukong — danger playground",
		Viewport:    engine.Size{W: logicalW, H: logicalH},
		WindowScale: 2,
		Actions:     actionMap(),
	}
	if err := platform.Run(config, &wukongGame{}); err != nil {
		log.Fatal(err)
	}
}
