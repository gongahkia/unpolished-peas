# first game tutorial

This tutorial builds the small game in [`example/first-game`](../example/first-game).
It creates an ECS entity, moves it with named input actions, and records
portable render commands. The game source uses public `engine` and `engine/ecs`
APIs; the render command types come from the technology-preview `engine/render`
package.

## prerequisites and reproducible build

72 currently requires Go 1.25. The v0.1 release dry-run uses Go 1.25.13;
the module baseline remains Go 1.25.0. From a clean checkout:

```sh
go mod download
go test ./example/first-game
make first-game-build
make first-game-wasm
```

The commands produce `bin/first-game` and the static wasm bundle in
`dist/first-game`. Run the desktop sample with:

```sh
make first-game-run
```

Serve the wasm bundle rather than opening it as `file://`:

```sh
python3 -m http.server --directory dist/first-game 8080
```

Then open <http://127.0.0.1:8080>. Use A/D or arrows to move and space to jump.

## Generated starter after v0.1

After v0.1 is published, this is the canonical way to start a new game. The
generator requires an explicit module path and refuses to create into an
existing directory:

```sh
go install github.com/gongahkia/72/cmd/72@v0.1.0
72 new -module example.com/me/my-game ./my-game
cd my-game
make test
make build
make wasm
make pack
```

`make wasm` writes a static bundle to `dist`; serve it with
`python3 -m http.server --directory dist 8080`. The starter includes one
embedded image, one asset manifest, and one test. It deliberately uses the
same small runtime contracts introduced below rather than a separate template
framework.

For a diagnostic bundle from the current target, run:

```sh
72 doctor -out 72-support.zip
```

The report is diagnostic evidence only. An available WebGPU fallback adapter
does not certify physical GPU or presentation support.

**Current host boundary:** the final call to `platform.Run` in
`example/first-game/main.go` owns the platform lifecycle and private WebGPU
renderer. Game code stays on the `engine` and `engine/render` contracts. The
Linux X11 startup and browser Chromium render/input/resize paths have local
coverage; other desktop targets and browser environments are not yet
runtime-certified.

## lifecycle and configuration

An application implements `engine.Application`. `Initialize` runs once after
runtime construction; `Update` receives the current immutable `engine.Input`
snapshot. Configure the viewport, title, scale, and game-owned action map:

```go
config := engine.Config{
    Title:       "72 first game",
    Viewport:    engine.Size{W: 320, H: 180},
    WindowScale: 3,
    Actions: engine.ActionMap{
        "move": {Axis: &engine.AxisBinding{
            Negative: []engine.Key{engine.KeyA, engine.KeyArrowLeft},
            Positive: []engine.Key{engine.KeyD, engine.KeyArrowRight},
        }},
        "jump": {Keys: []engine.Key{engine.KeySpace}},
    },
}
```

`Input.Axis("move")` is `-1`, `0`, or `1` for the declared keyboard direction.
Use `Pressed`, `Released`, and `Down` for edge/held behavior. For a host you
own, pass normalized `engine.Event` batches through `Runtime.SampleInput`; see
[portable input](INPUT.md) for rebinding, pointer, text, gamepad, and
focus-loss semantics.

## ECS state

The example's `playerPosition` is a game-owned component. It is created on an
entity in `Initialize`, read in `Update`, then replaced with `ecs.Set`:

```go
player := runtime.World().Spawn()
if err := ecs.Add(runtime.World(), player, playerPosition{X: 150, Y: 90}); err != nil {
    return err
}

position, ok := ecs.Get[playerPosition](runtime.World(), player)
position.X += input.Axis("move") * 3
return ecs.Set(runtime.World(), player, position)
```

Use `ecs.Each` or `ecs.Each2` for stable entity-order iteration, resources for
singletons, and a plugin/schedule when a game needs named phase ordering. ECS
data stays game-owned; the engine only supplies deterministic storage and
execution boundaries.

## rendering

The sample adds two screen-space command layers. One clears the frame; the
other reads the ECS position and records a rectangle plus text:

```go
return runtime.Layers().Add(engine.Layer{
    ID: "player", Order: 1, Space: engine.ScreenSpace,
    DrawCommands: func(frame engine.CommandFrame) error {
        return frame.FillRect(render.RectDraw{
            Bounds: render.Rect{X: position.X, Y: position.Y, W: 18, H: 18},
            Color: render.Color{R: 94, G: 230, B: 160, A: 255},
        })
    },
})
```

`engine/render` records backend-neutral command intent. It is a technology
preview, so keep its types out of a game’s own long-lived public API.

## assets

Load portable source data with `engine/assets`, then create a runtime texture
from the result. Paths are project-relative and decoded values are copied:

```go
manager := assets.NewManager(os.DirFS("."))
imageHandle, err := assets.Load(manager, "art/player.png", assets.DecodeImage)
if err != nil {
    return err
}
image, ok := assets.Get(manager, imageHandle)
texture, err := runtime.Textures().Create(image)
```

`DecodeImage` supports PNG, JPEG, and GIF. `DecodeFont`, `DecodeWAV`, and
`DecodeTileMap` supply the other standard portable formats. See
[assets](ASSETS.md) and [asset packaging](ASSET_PACKAGING.md) for validation,
reload, and package-manifest details. Assets and render APIs are technology
preview packages; the engine/runtime lifecycle and ECS APIs above are the
supported core.

## verification boundary

`example/first-game/main_test.go` proves the public runtime lifecycle, ECS
movement, and emitted high-level commands without importing a graphics binding.
The desktop and wasm build commands prove compilation only. The local Linux
startup smoke is not a browser or cross-platform certification.
