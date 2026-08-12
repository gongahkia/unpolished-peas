//go:build darwin

package webgpu

import (
	"fmt"

	"github.com/gogpu/wgpu"
)

// NewMetalLayer creates a renderer for a host-owned CAMetalLayer. The layer
// and its containing NSView/NSWindow must remain valid until Close returns.
func NewMetalLayer(layer uintptr, width, height int) (*Renderer, error) {
	if layer == 0 {
		return nil, fmt.Errorf("create WebGPU Metal surface: layer must not be null")
	}
	instance, err := wgpu.CreateInstance(nil)
	if err != nil {
		return nil, fmt.Errorf("create WebGPU instance: %w", err)
	}
	surface, err := instance.CreateSurfaceUnsafe(wgpu.SurfaceTargetFromMetalLayer(layer))
	if err != nil {
		instance.Release()
		return nil, fmt.Errorf("create WebGPU Metal surface: %w", err)
	}
	return newRenderer(instance, surface, width, height)
}
