//go:build !(js && wasm)

package webgpu

import (
	"fmt"

	"github.com/gogpu/wgpu"
	_ "github.com/gogpu/wgpu/hal/allbackends"
)

// NewXlib creates a renderer for a host-owned Xlib Display* and Window. The
// display and window must remain valid until Close returns.
func NewXlib(display, window uintptr, width, height int) (*Renderer, error) {
	instance, err := wgpu.CreateInstance(nil)
	if err != nil {
		return nil, fmt.Errorf("create WebGPU instance: %w", err)
	}
	surface, err := instance.CreateSurfaceUnsafe(wgpu.SurfaceTargetFromXlibWindow(display, window))
	if err != nil {
		instance.Release()
		return nil, fmt.Errorf("create WebGPU Xlib surface: %w", err)
	}
	return newRenderer(instance, surface, width, height)
}

// NewHeadless creates a software-capable private renderer target for local
// integration checks. It is not a user-facing presentation host.
func NewHeadless(width, height int) (*Renderer, error) {
	instance, err := wgpu.CreateInstance(nil)
	if err != nil {
		return nil, fmt.Errorf("create WebGPU instance: %w", err)
	}
	surface, err := instance.CreateSurfaceFromTarget(wgpu.HeadlessSurfaceTarget{})
	if err != nil {
		instance.Release()
		return nil, fmt.Errorf("create WebGPU headless surface: %w", err)
	}
	return newRenderer(instance, surface, width, height)
}
