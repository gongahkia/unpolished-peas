package ebiten

import (
	"reflect"
	"testing"

	"github.com/gongahkia/72/engine"
)

func TestConfiguredKeysIncludesEachDigitalBindingOnceInStableOrder(t *testing.T) {
	keys := configuredKeys(engine.ActionMap{
		"confirm": {Keys: []engine.Key{engine.KeyEnter, engine.KeyA}},
		"move": {Axis: &engine.AxisBinding{
			Negative: []engine.Key{engine.KeyA, engine.KeyArrowLeft},
			Positive: []engine.Key{engine.KeyArrowRight, engine.KeyA},
		}},
	})
	want := []engine.Key{engine.KeyA, engine.KeyArrowLeft, engine.KeyArrowRight, engine.KeyEnter}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("configured keys = %v, want %v", keys, want)
	}
}
