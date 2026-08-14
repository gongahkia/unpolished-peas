package main

import (
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const starterPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQI12OIe7bgPwAGbgLkaqSUagAAAABJRU5ErkJggg=="

type starterFile struct {
	path string
	data string
}

func runNew(arguments []string, stdout, stderr io.Writer) (err error) {
	flags := flag.NewFlagSet("new", flag.ContinueOnError)
	flags.SetOutput(stderr)
	modulePath := flags.String("module", "", "Go module path, for example example.com/me/game")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if strings.TrimSpace(*modulePath) == "" {
		return errors.New("new requires -module")
	}
	if !validModulePath(*modulePath) {
		return fmt.Errorf("new module path %q is invalid", *modulePath)
	}
	if flags.NArg() != 1 {
		return errors.New("new requires exactly one destination directory")
	}
	destination, err := filepath.Abs(flags.Arg(0))
	if err != nil {
		return fmt.Errorf("resolve new destination: %w", err)
	}
	if _, err := os.Lstat(destination); err == nil {
		return fmt.Errorf("new destination %q already exists", destination)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect new destination %q: %w", destination, err)
	}
	if err := os.Mkdir(destination, 0o755); err != nil {
		return fmt.Errorf("create new destination %q: %w", destination, err)
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(destination)
		}
	}()
	for _, file := range starterFiles(*modulePath) {
		path := filepath.Join(destination, file.path)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return fmt.Errorf("create starter directory for %q: %w", file.path, err)
		}
		if err := os.WriteFile(path, []byte(file.data), 0o644); err != nil {
			return fmt.Errorf("write starter file %q: %w", file.path, err)
		}
	}
	png, err := base64.StdEncoding.DecodeString(starterPNG)
	if err != nil {
		return fmt.Errorf("decode starter image: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(destination, "assets"), 0o755); err != nil {
		return fmt.Errorf("create starter asset directory: %w", err)
	}
	if err := os.WriteFile(filepath.Join(destination, "assets", "player.png"), png, 0o644); err != nil {
		return fmt.Errorf("write starter image: %w", err)
	}
	_, err = fmt.Fprintf(stdout, "created 72 game module %s in %s\n", *modulePath, destination)
	return err
}

func validModulePath(value string) bool {
	if strings.TrimSpace(value) != value || value == "" || strings.ContainsAny(value, "\\\\:@ \t\r\n") {
		return false
	}
	for _, segment := range strings.Split(value, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

func starterFiles(modulePath string) []starterFile {
	replace := func(value string) string { return strings.ReplaceAll(value, "{{MODULE}}", modulePath) }
	return []starterFile{
		{path: "go.mod", data: replace(`module {{MODULE}}

go 1.25.0

require github.com/gongahkia/72 v0.1.0
`)},
		{path: "main.go", data: starterMain},
		{path: "main_test.go", data: starterTest},
		{path: "72.assets.json", data: `{"version":1,"name":"starter-game","assets":[{"path":"assets/player.png","type":"image","mode":"embed"}]}
`},
		{path: "Makefile", data: starterMakefile},
		{path: "web/index.html", data: starterHTML},
		{path: ".gitignore", data: "/bin/\n/dist/\n"},
		{path: "README.md", data: starterREADME},
	}
}

const starterMain = `// Command starter-game is the minimal 72 v0.1 game template.
package main

import (
	"embed"
	"fmt"
	"log"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/assets"
	"github.com/gongahkia/72/engine/ecs"
	"github.com/gongahkia/72/engine/platform"
	"github.com/gongahkia/72/engine/render"
)

//go:embed assets/player.png
var projectAssets embed.FS

const actionMove engine.Action = "move"

type playerPosition struct{ X, Y float64 }

type game struct {
	player  ecs.Entity
	runtime *engine.Runtime
	texture render.Texture
}

func (g *game) Initialize(runtime *engine.Runtime) error {
	g.runtime = runtime
	manager := assets.NewManager(projectAssets)
	imageHandle, err := assets.Load(manager, "assets/player.png", assets.DecodeImage)
	if err != nil {
		return err
	}
	image, ok := assets.Get(manager, imageHandle)
	if !ok {
		return fmt.Errorf("starter image was not loaded")
	}
	g.texture, err = runtime.Textures().Create(image)
	if err != nil {
		return err
	}
	g.player = runtime.World().Spawn()
	if err := ecs.Add(runtime.World(), g.player, playerPosition{X: 150, Y: 90}); err != nil {
		return err
	}
	if err := runtime.Layers().Add(engine.Layer{ID: "background", Order: 0, Space: engine.ScreenSpace, DrawCommands: func(frame engine.CommandFrame) error {
		return frame.Clear(render.Color{R: 18, G: 27, B: 46, A: 255})
	}}); err != nil {
		return err
	}
	return runtime.Layers().Add(engine.Layer{ID: "player", Order: 1, Space: engine.ScreenSpace, DrawCommands: func(frame engine.CommandFrame) error {
		position, ok := ecs.Get[playerPosition](g.runtime.World(), g.player)
		if !ok {
			return fmt.Errorf("player entity lost its position component")
		}
		if err := frame.DrawSprite(render.Sprite{Texture: g.texture, Bounds: render.Rect{X: position.X, Y: position.Y, W: 18, H: 18}, Tint: render.Color{R: 94, G: 230, B: 160, A: 255}}); err != nil {
			return err
		}
		return frame.DrawText(render.TextDraw{Position: render.Vec2{X: 10, Y: 18}, Value: "A/D or arrows move", Color: render.Color{R: 235, G: 242, B: 255, A: 255}})
	}})
}

func (g *game) Update(input engine.Input) error {
	position, ok := ecs.Get[playerPosition](g.runtime.World(), g.player)
	if !ok {
		return fmt.Errorf("player entity lost its position component")
	}
	position.X += input.Axis(actionMove) * 3
	return ecs.Set(g.runtime.World(), g.player, position)
}

func main() {
	config := engine.Config{Title: "72 starter game", Viewport: engine.Size{W: 320, H: 180}, WindowScale: 3, Actions: engine.ActionMap{
		actionMove: {Axis: &engine.AxisBinding{Negative: []engine.Key{engine.KeyA, engine.KeyArrowLeft}, Positive: []engine.Key{engine.KeyD, engine.KeyArrowRight}}},
	}}
	if err := platform.Run(config, &game{}); err != nil {
		log.Fatal(err)
	}
}
`

const starterTest = `package main

import (
	"testing"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/ecs"
)

func TestStarterGameMovesPlayer(t *testing.T) {
	game := &game{}
	runtime, err := engine.NewRuntime(engine.Config{Viewport: engine.Size{W: 320, H: 180}, WindowScale: 1, Actions: engine.ActionMap{actionMove: {Axis: &engine.AxisBinding{Positive: []engine.Key{engine.KeyD}}}}}, game)
	if err != nil {
		t.Fatal(err)
	}
	if err := runtime.Update(engine.NewInput(map[engine.Action]engine.ActionState{actionMove: {Down: true, Value: 1}})); err != nil {
		t.Fatal(err)
	}
	position, ok := ecs.Get[playerPosition](runtime.World(), game.player)
	if !ok || position.X != 153 {
		t.Fatalf("player position = %+v, present=%t", position, ok)
	}
}
`

const starterMakefile = `.PHONY: run test build wasm pack

run:
	go run .

test:
	go test ./...

build:
	mkdir -p bin
	go build -o bin/starter-game .

wasm:
	mkdir -p dist
	GOOS=js GOARCH=wasm go build -o dist/starter-game.wasm .
	cp "$$(go env GOROOT)/lib/wasm/wasm_exec.js" dist/wasm_exec.js
	cp web/index.html dist/index.html

pack:
	mkdir -p dist
	go run github.com/gongahkia/72/cmd/72@v0.1.0 pack -root . -out dist/starter-game.72.json
`

const starterHTML = `<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>72 starter game</title></head>
  <body>
    <canvas aria-label="72 starter game"></canvas>
    <script src="wasm_exec.js"></script>
    <script>
      const go = new Go();
      WebAssembly.instantiateStreaming(fetch("starter-game.wasm"), go.importObject)
        .then(({ instance }) => go.run(instance))
        .catch((error) => document.body.append(` + "`WASM startup failed: ${error}`" + `));
    </script>
  </body>
</html>
`

const starterREADME = `# 72 starter game

Run ` + "`make test`" + `, ` + "`make build`" + `, or ` + "`make wasm`" + `. Serve ` + "`dist`" + ` from an HTTP origin for browser use. Build the declared asset package with ` + "`make pack`" + `.
`
