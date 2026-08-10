package render

import (
	"fmt"
	"sync"
)

// Image is a portable, non-premultiplied RGBA8 texture source. Pixels are in
// row-major order and contain exactly four bytes per pixel.
type Image struct {
	Width, Height int
	Pixels        []byte
}

// NewImage validates and copies an RGBA8 texture source.
func NewImage(width, height int, pixels []byte) (Image, error) {
	if width <= 0 || height <= 0 {
		return Image{}, fmt.Errorf("image dimensions must be positive")
	}
	if width > maxInt()/height/4 || len(pixels) != width*height*4 {
		return Image{}, fmt.Errorf("image has %d pixels bytes, want %d", len(pixels), width*height*4)
	}
	return Image{Width: width, Height: height, Pixels: append([]byte(nil), pixels...)}, nil
}

// TextureStore owns portable source data for backend-created texture resources.
// Texture handles are stable for the lifetime of the store.
type TextureStore struct {
	mu     sync.RWMutex
	nextID uint64
	images map[uint64]Image
}

// NewTextureStore creates an empty texture source store.
func NewTextureStore() *TextureStore { return &TextureStore{images: make(map[uint64]Image)} }

// Create registers source and returns an opaque texture handle.
func (s *TextureStore) Create(source Image) (Texture, error) {
	if source.Width <= 0 || source.Height <= 0 || source.Width > maxInt()/source.Height/4 || len(source.Pixels) != source.Width*source.Height*4 {
		return Texture{}, fmt.Errorf("texture source is not a valid RGBA8 image")
	}
	s.mu.Lock()
	s.nextID++
	texture := Texture{ID: s.nextID}
	s.images[texture.ID] = Image{Width: source.Width, Height: source.Height, Pixels: append([]byte(nil), source.Pixels...)}
	s.mu.Unlock()
	return texture, nil
}

// Image returns a copy of source data for texture.
func (s *TextureStore) Image(texture Texture) (Image, bool) {
	if s == nil || texture.ID == 0 {
		return Image{}, false
	}
	s.mu.RLock()
	image, ok := s.images[texture.ID]
	s.mu.RUnlock()
	if !ok {
		return Image{}, false
	}
	image.Pixels = append([]byte(nil), image.Pixels...)
	return image, true
}

func maxInt() int { return int(^uint(0) >> 1) }
