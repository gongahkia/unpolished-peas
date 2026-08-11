# first game tutorial

This tutorial builds the small game in [`example/first-game`](../example/first-game).
It creates an ECS entity, moves it with named input actions, and records
portable render commands. The game source uses public `engine` and `engine/ecs`
APIs; the render command types come from the technology-preview `engine/render`
package.

## prerequisites and reproducible build

72 currently requires Go 1.25. From a clean checkout:

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

**Current host boundary:** the final call to `engineebiten.Run` in
`example/first-game/main.go` is a transitional compatibility bootstrap. It is
the only part that does not belong to the supported-runtime tier in
[the public API policy](PUBLIC_API.md). No supported native or browser host
exists yet because the WebGPU dependency gate remains unresolved by design. Do
not use that adapter as a template for a long-lived platform integration; use
the `engine.Host` contract when a supported host is available.

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
preview, so keep its types out of a game’s own long-lived public API. The
temporary adapter can draw its primitives today; the engine-owned renderer is
not yet a supported target.

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
movement, and emitted high-level commands without importing Ebitengine. The
desktop and wasm build commands prove compilation only. A manual desktop/wasm
run exercises the transitional adapter; it does not establish a supported
engine-owned host or renderer claim.
