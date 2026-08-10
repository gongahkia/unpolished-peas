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
