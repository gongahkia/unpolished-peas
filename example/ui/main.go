// Command ui is a runnable retained-UI sample.
//
// It uses normalized engine input and command-frame rendering only. The final
// Run call uses the temporary Ebitengine adapter until engine-owned hosts are
// available.
package main

import (
	"fmt"
	"log"

	"github.com/gongahkia/72/engine"
	engineebiten "github.com/gongahkia/72/engine/ebiten"
	"github.com/gongahkia/72/engine/render"
	"github.com/gongahkia/72/engine/ui"
)

const (
	actionFocusNext     engine.Action = "ui-focus-next"
	actionFocusPrevious engine.Action = "ui-focus-previous"
	actionActivate      engine.Action = "ui-activate"
)

type sampleUI struct {
	tree               *ui.Tree
	start, preferences ui.NodeID
	status             ui.NodeID
	message            string
}

func (s *sampleUI) Initialize(runtime *engine.Runtime) error {
	s.tree = ui.NewTree(ui.Style{Direction: ui.Column, Padding: 12, Gap: 8})
	var err error
	if s.start, err = s.tree.Add(s.tree.Root(), ui.Style{Height: 32, Interactive: true}, nil); err != nil {
		return err
	}
	if s.preferences, err = s.tree.Add(s.tree.Root(), ui.Style{Height: 32, Interactive: true}, nil); err != nil {
		return err
	}
	if s.status, err = s.tree.Add(s.tree.Root(), ui.Style{Height: 24}, nil); err != nil {
		return err
	}
	viewport := runtime.Config().Viewport
	if err := s.tree.Layout(ui.Vec2{X: viewport.W, Y: viewport.H}); err != nil {
		return err
	}
	s.message = "choose an option"
	if err := s.refreshVisuals(); err != nil {
		return err
	}
	return runtime.Layers().Add(engine.Layer{
		ID:    "ui",
		Order: 0,
		Space: engine.ScreenSpace,
		DrawCommands: func(frame engine.CommandFrame) error {
			if err := frame.Clear(render.Color{R: 12, G: 16, B: 26, A: 255}); err != nil {
				return err
			}
			if err := s.tree.Layout(ui.Vec2{X: frame.Viewport.W, Y: frame.Viewport.H}); err != nil {
				return err
			}
			return s.tree.Render(frame)
		},
	})
}

func (s *sampleUI) Update(input engine.Input) error {
	keyboard := ui.KeyboardInput{
		FocusNext:     input.Pressed(actionFocusNext),
		FocusPrevious: input.Pressed(actionFocusPrevious),
		Activate:      input.Pressed(actionActivate),
	}
	if target, ok := s.tree.DispatchKeyboard(keyboard); ok && keyboard.Activate && !keyboard.FocusNext && !keyboard.FocusPrevious {
		s.activate(target)
	}
	pointer := input.Pointer()
	button := pointer.Button(engine.PointerPrimary)
	if button.Pressed || button.Released {
		target, ok := s.tree.DispatchPointer(ui.PointerEvent{
			Position: ui.Vec2{X: pointer.Position.X, Y: pointer.Position.Y},
			Pressed:  button.Pressed,
			Released: button.Released,
		})
		if ok && button.Released {
			s.activate(target)
		}
	}
	return s.refreshVisuals()
}

func (s *sampleUI) activate(target ui.NodeID) {
	switch target {
	case s.start:
		s.message = "start selected"
	case s.preferences:
		s.message = "preferences selected"
	}
}

func (s *sampleUI) refreshVisuals() error {
	if s.tree == nil {
		return fmt.Errorf("UI tree is not initialized")
	}
	if err := s.tree.SetContent(s.tree.Root(), ui.Visual{DrawFill: true, Fill: render.Color{R: 25, G: 34, B: 52, A: 255}}); err != nil {
		return err
	}
	if err := s.tree.SetContent(s.start, s.buttonVisual("start")); err != nil {
		return err
	}
	if err := s.tree.SetContent(s.preferences, s.buttonVisual("preferences")); err != nil {
		return err
	}
	return s.tree.SetContent(s.status, ui.Visual{
		DrawFill:     true,
		Fill:         render.Color{R: 18, G: 25, B: 39, A: 255},
		Text:         s.message,
		TextColor:    render.Color{R: 181, G: 194, B: 214, A: 255},
		TextPosition: ui.Vec2{X: 8, Y: 16},
	})
}

func (s *sampleUI) buttonVisual(label string) ui.Visual {
	focused := false
	if focus, ok := s.tree.Focus(); ok {
		focused = focus == s.start && label == "start" || focus == s.preferences && label == "preferences"
	}
	fill := render.Color{R: 44, G: 57, B: 82, A: 255}
	border := render.Color{R: 101, G: 124, B: 165, A: 255}
	if focused {
		fill = render.Color{R: 58, G: 95, B: 143, A: 255}
		border = render.Color{R: 230, G: 238, B: 255, A: 255}
	}
	return ui.Visual{
		DrawFill:     true,
		Fill:         fill,
		Border:       border,
		BorderWidth:  1,
		Text:         label,
		TextColor:    render.Color{R: 235, G: 242, B: 255, A: 255},
		TextPosition: ui.Vec2{X: 10, Y: 21},
	}
}

func sampleConfig() engine.Config {
	return engine.Config{
		Title:       "72 retained UI sample",
		Viewport:    engine.Size{W: 320, H: 180},
		WindowScale: 3,
		Actions: engine.ActionMap{
			actionFocusNext:     {Keys: []engine.Key{engine.KeyArrowDown, engine.KeyTab}},
			actionFocusPrevious: {Keys: []engine.Key{engine.KeyArrowUp}},
			actionActivate:      {Keys: []engine.Key{engine.KeyEnter, engine.KeySpace}},
		},
	}
}

func main() {
	if err := engineebiten.Run(sampleConfig(), &sampleUI{}); err != nil {
		log.Fatal(err)
	}
}
