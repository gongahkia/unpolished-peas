package render

import "testing"

func TestTextureStoreOwnsPortableTextureData(t *testing.T) {
	image, err := NewImage(2, 1, []byte{1, 2, 3, 4, 5, 6, 7, 8})
	if err != nil {
		t.Fatal(err)
	}
	store := NewTextureStore()
	texture, err := store.Create(image)
	if err != nil {
		t.Fatal(err)
	}
	image.Pixels[0] = 99
	loaded, ok := store.Image(texture)
	if !ok || loaded.Pixels[0] != 1 {
		t.Fatalf("texture source = %+v, %t", loaded, ok)
	}
	loaded.Pixels[1] = 99
	again, _ := store.Image(texture)
	if again.Pixels[1] != 2 {
		t.Fatalf("texture image leaked mutable pixels: %v", again.Pixels)
	}
	if _, err := NewImage(1, 1, []byte{1}); err == nil {
		t.Fatal("invalid RGBA image succeeded")
	}
}

func TestTextureStoreCreatesAndValidatesRenderTargets(t *testing.T) {
	store := NewTextureStore()
	target, err := store.CreateRenderTarget(2, 1)
	if err != nil {
		t.Fatal(err)
	}
	image, ok := store.TargetImage(target)
	if !ok || image.Width != 2 || image.Height != 1 || len(image.Pixels) != 8 {
		t.Fatalf("target image = %+v, present=%t", image, ok)
	}
	if _, err := store.CreateRenderTarget(0, 1); err == nil {
		t.Fatal("zero-width render target succeeded")
	}
	if _, ok := store.TargetImage(RenderTarget{Texture: Texture{ID: target.Texture.ID + 1}}); ok {
		t.Fatal("unknown render target was available")
	}
}

func TestTextureStoreReportsPortableStorage(t *testing.T) {
	store := NewTextureStore()
	if _, err := store.Create(Image{Width: 1, Height: 1, Pixels: []byte{1, 2, 3, 4}}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateRenderTarget(2, 1); err != nil {
		t.Fatal(err)
	}
	if got, want := store.Stats(), (TextureStats{Count: 2, RenderTargetCount: 1, Bytes: 12, RenderTargetBytes: 8}); got != want {
		t.Fatalf("texture stats = %+v, want %+v", got, want)
	}
}

func TestTextureStoreReplacesAndReleasesRegularTextureSources(t *testing.T) {
	store := NewTextureStore()
	texture, err := store.Create(Image{Width: 1, Height: 1, Pixels: []byte{1, 2, 3, 4}})
	if err != nil {
		t.Fatal(err)
	}
	first, ok := store.Source(texture)
	if !ok || first.Revision != 1 || first.RenderTarget || first.Image.Pixels[0] != 1 {
		t.Fatalf("initial source = %+v, present=%t", first, ok)
	}
	if revision, target, ok := store.Revision(texture); !ok || revision != 1 || target {
		t.Fatalf("initial revision = %d, target=%t, present=%t", revision, target, ok)
	}
	if err := store.Replace(texture, Image{Width: 2, Height: 1, Pixels: []byte{5, 6, 7, 8, 9, 10, 11, 12}}); err != nil {
		t.Fatal(err)
	}
	second, ok := store.Source(texture)
	if !ok || second.Revision != 2 || second.Image.Width != 2 || second.Image.Pixels[0] != 5 {
		t.Fatalf("replaced source = %+v, present=%t", second, ok)
	}
	second.Image.Pixels[0] = 99
	again, _ := store.Source(texture)
	if again.Image.Pixels[0] != 5 {
		t.Fatalf("replaced source leaked mutable pixels: %v", again.Image.Pixels)
	}
	if !store.Release(texture) || store.Release(texture) {
		t.Fatal("release did not report one removed source")
	}
	if _, ok := store.Source(texture); ok {
		t.Fatal("released texture remained available")
	}
	if err := store.Replace(texture, Image{Width: 1, Height: 1, Pixels: []byte{1, 2, 3, 4}}); err == nil {
		t.Fatal("replaced released texture")
	}
}

func TestTextureStoreProtectsRenderTargetsFromReplaceAndReleasesThem(t *testing.T) {
	store := NewTextureStore()
	target, err := store.CreateRenderTarget(1, 1)
	if err != nil {
		t.Fatal(err)
	}
	source, ok := store.Source(target.Texture)
	if !ok || source.Revision != 1 || !source.RenderTarget {
		t.Fatalf("target source = %+v, present=%t", source, ok)
	}
	if err := store.Replace(target.Texture, Image{Width: 1, Height: 1, Pixels: []byte{1, 2, 3, 4}}); err == nil {
		t.Fatal("replaced render target")
	}
	if !store.Release(target.Texture) {
		t.Fatal("release render target failed")
	}
	if _, ok := store.TargetImage(target); ok {
		t.Fatal("released render target remained available")
	}
}
