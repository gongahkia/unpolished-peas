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
	expected, ok := imageByteLen(width, height)
	if !ok {
		return Image{}, fmt.Errorf("image dimensions must be positive and addressable")
	}
	if len(pixels) != expected {
		return Image{}, fmt.Errorf("image has %d pixel bytes, want %d", len(pixels), expected)
	}
	return Image{Width: width, Height: height, Pixels: append([]byte(nil), pixels...)}, nil
}

// TextureStore owns portable source data for backend-created texture resources.
// Texture handles are stable for the lifetime of the store.
type TextureStore struct {
	mu      sync.RWMutex
	nextID  uint64
	images  map[uint64]Image
	targets map[uint64]struct{}
}

// TextureStats reports the portable RGBA8 source data currently retained by a
// TextureStore. Bytes includes render-target images; RenderTargetBytes is its
// subset. It does not estimate backend-native allocations.
type TextureStats struct {
	Count, RenderTargetCount uint64
	Bytes, RenderTargetBytes uint64
}

// NewTextureStore creates an empty texture source store.
func NewTextureStore() *TextureStore {
	return &TextureStore{images: make(map[uint64]Image), targets: make(map[uint64]struct{})}
}

// Create registers source and returns an opaque texture handle.
func (s *TextureStore) Create(source Image) (Texture, error) {
	expected, ok := imageByteLen(source.Width, source.Height)
	if !ok || len(source.Pixels) != expected {
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

// Stats returns a point-in-time summary of portable texture source storage.
func (s *TextureStore) Stats() TextureStats {
	if s == nil {
		return TextureStats{}
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	stats := TextureStats{Count: uint64(len(s.images)), RenderTargetCount: uint64(len(s.targets))}
	for id, image := range s.images {
		bytes := uint64(len(image.Pixels))
		stats.Bytes += bytes
		if _, target := s.targets[id]; target {
			stats.RenderTargetBytes += bytes
		}
	}
	return stats
}

// CreateRenderTarget registers a transparent portable image that can be used
// as an off-screen renderer destination. Its Texture is valid for later sprite
// sampling after a TargetBackend successfully renders into it.
func (s *TextureStore) CreateRenderTarget(width, height int) (RenderTarget, error) {
	length, ok := imageByteLen(width, height)
	if !ok {
		return RenderTarget{}, fmt.Errorf("render target dimensions must be positive and addressable")
	}
	image, err := NewImage(width, height, make([]byte, length))
	if err != nil {
		return RenderTarget{}, err
	}
	texture, err := s.Create(image)
	if err != nil {
		return RenderTarget{}, err
	}
	s.mu.Lock()
	s.targets[texture.ID] = struct{}{}
	s.mu.Unlock()
	return RenderTarget{Texture: texture}, nil
}

// TargetImage returns a copy of a registered render target's portable source.
// It is intended for backend rehydration and deterministic tests, not GPU
// readback from an arbitrary renderer.
func (s *TextureStore) TargetImage(target RenderTarget) (Image, bool) {
	if s == nil || target.Texture.ID == 0 {
		return Image{}, false
	}
	s.mu.RLock()
	_, targetOK := s.targets[target.Texture.ID]
	image, imageOK := s.images[target.Texture.ID]
	s.mu.RUnlock()
	if !targetOK || !imageOK {
		return Image{}, false
	}
	image.Pixels = append([]byte(nil), image.Pixels...)
	return image, true
}

func (s *TextureStore) replaceTarget(target RenderTarget, source Image) error {
	if s == nil || target.Texture.ID == 0 {
		return fmt.Errorf("render target must not be zero")
	}
	if !validImage(source) {
		return fmt.Errorf("render target source is not a valid RGBA8 image")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.targets[target.Texture.ID]; !ok {
		return fmt.Errorf("texture %d is not a render target", target.Texture.ID)
	}
	current, ok := s.images[target.Texture.ID]
	if !ok {
		return fmt.Errorf("render target texture %d is not registered", target.Texture.ID)
	}
	if current.Width != source.Width || current.Height != source.Height {
		return fmt.Errorf("render target dimensions changed from %dx%d to %dx%d", current.Width, current.Height, source.Width, source.Height)
	}
	s.images[target.Texture.ID] = Image{Width: source.Width, Height: source.Height, Pixels: append([]byte(nil), source.Pixels...)}
	return nil
}

func imageByteLen(width, height int) (int, bool) {
	if width <= 0 || height <= 0 || width > maxInt()/height/4 {
		return 0, false
	}
	return width * height * 4, true
}

func maxInt() int { return int(^uint(0) >> 1) }
