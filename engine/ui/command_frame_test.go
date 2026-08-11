package ui_test

import (
	"testing"

	"github.com/gongahkia/72/engine"
	"github.com/gongahkia/72/engine/ui"
)

func TestCommandFrameImplementsUICommandRenderer(t *testing.T) {
	var renderer ui.CommandRenderer = engine.CommandFrame{}
	if renderer == nil {
		t.Fatal("command frame did not implement UI command renderer")
	}
}
