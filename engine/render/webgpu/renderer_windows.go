//go:build windows

package webgpu

import (
	"fmt"

	"github.com/gogpu/wgpu"
)

// NewWin32 creates a renderer for a host-owned Win32 HWND. The window must
// remain valid until Close returns.
func NewWin32(window uintptr, width, height int) (*Renderer, error) {
	if window == 0 {
		return nil, fmt.Errorf("create WebGPU Win32 surface: window must not be null")
	}
	instance, err := wgpu.CreateInstance(nil)
	if err != nil {
		return nil, fmt.Errorf("create WebGPU instance: %w", err)
	}
	surface, err := instance.CreateSurfaceUnsafe(wgpu.SurfaceTargetFromWindowsHWND(0, window))
	if err != nil {
		instance.Release()
		return nil, fmt.Errorf("create WebGPU Win32 surface: %w", err)
	}
	return newRenderer(instance, surface, width, height)
}
