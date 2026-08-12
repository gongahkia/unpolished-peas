# Retained UI

`engine/ui` is a technology-preview retained layout tree. It owns layout, hit
testing, focus traversal, pointer capture, and optional command-frame visual
emission; games retain widget state and activation behavior.

## Frame flow

Lay out the tree whenever the logical viewport changes. Map portable game
actions to `ui.KeyboardInput`, send pointer transitions through
`DispatchPointer`, then render visual content from a screen-space command layer.

```go
tree := ui.NewTree(ui.Style{Direction: ui.Column, Padding: 8, Gap: 4})
button, _ := tree.Add(tree.Root(), ui.Style{Height: 24, Interactive: true}, ui.Visual{
    DrawFill: true,
    Fill: render.Color{R: 40, G: 44, B: 52, A: 255},
    Text: "start",
    TextColor: render.Color{R: 255, G: 255, B: 255, A: 255},
    TextPosition: ui.Vec2{X: 6, Y: 16},
})

// during an update, after translating engine.Input actions:
if target, activated := tree.DispatchKeyboard(ui.KeyboardInput{Activate: input.Pressed("ui-activate")}); activated && target == button {
    // update game state
}

// during a screen-space CommandDrawFunc:
if err := tree.Layout(ui.Vec2{X: frame.Viewport.W, Y: frame.Viewport.H}); err != nil {
    return err
}
return tree.Render(frame)
```

`engine.CommandFrame` owns the queue, layer ordering, and coordinate space. It
implements `ui.ClipCommandRenderer`, so a screen-space command layer can pass
its frame directly to `Tree.Render`. Existing `ui.CommandRenderer` values that
lack clip operations remain source-compatible, but `Tree.Render` returns an
error for them because retained visual rendering requires nested clipping.

## Input policy

`FocusNext` and `FocusPrevious` cycle through interactive nodes in retained
painter order and wrap. `Activate` returns the focused node ID; the tree never
calls application callbacks. A pointer press on an interactive node sets focus
and captures it. Its release is delivered to the captured node even after the
pointer moves outside the bounds. Call `CancelPointer` after focus loss or a
platform gesture cancellation.

## Rendering policy and current limits

`Visual` emits its optional fill, border, and text in parent-before-child
painter order using the existing `engine/render` rectangle and text commands.
Text coordinates are baselines relative to the node's top-left corner. The
optional `Tree.SetTextAtlas` attachment forwards an engine-owned
`render.GlyphAtlas` to a node's text command; passing nil restores the
basic-font compatibility path. The tree validates finite geometry and clips
every node's visuals and descendants
to its bounds through the nested screen-space command clip contract; its hit
tests use the same ancestor boundary. Render targets and a production GPU
text/render path remain unimplemented.

## Runnable sample

`example/ui` is a small command-only retained-UI sample. It maps arrow/tab,
enter/space, and primary-pointer events to two interactive buttons, then draws
the tree through one screen-space command layer. Run it with `make
ui-sample-run`, or build its desktop and wasm artifacts with `make
ui-sample-build` and `make ui-sample-wasm`.

The sample uses `engine/platform` and the engine-owned renderer. Its native and
wasm builds demonstrate integration; they are not browser-runtime or
cross-platform support evidence.
