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

func TestResetResourcesDropsPrivateCachesWithoutResettingUploads(t *testing.T) {
	backend := NewRenderBackend(nil)
	backend.textures[1] = textureCache{revision: 2}
	backend.renderTargets[2] = textureCache{revision: 3}
	backend.atlasTextures[atlasPageKey{}] = atlasPageTexture{revision: 4}
	backend.textureUploads = 5

	backend.ResetResources()

	if len(backend.textures) != 0 || len(backend.renderTargets) != 0 || len(backend.atlasTextures) != 0 || backend.textureUploads != 5 {
		t.Fatalf("reset resources = textures:%d targets:%d atlas:%d uploads:%d", len(backend.textures), len(backend.renderTargets), len(backend.atlasTextures), backend.textureUploads)
	}
}
