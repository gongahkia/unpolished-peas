//go:build js && wasm

package webgpu

import (
	"fmt"
	"syscall/js"

	"github.com/gogpu/wgpu"
)

// NewCanvas creates a renderer for a host-owned HTMLCanvasElement. The canvas
// and its JavaScript realm must remain valid until Close returns.
func NewCanvas(canvas js.Value, width, height int) (*Renderer, error) {
	if canvas.IsNull() || canvas.IsUndefined() {
		return nil, fmt.Errorf("create WebGPU canvas renderer: canvas must not be null")
	}
	instance, err := wgpu.CreateInstance(nil)
	if err != nil {
		return nil, fmt.Errorf("create WebGPU instance: %w", err)
	}
	surface, err := instance.CreateSurfaceFromCanvas(canvas)
	if err != nil {
		instance.Release()
		return nil, fmt.Errorf("create WebGPU canvas surface: %w", err)
	}
	return newRendererWithFormat(instance, surface, width, height, preferredCanvasFormat())
}

func preferredCanvasFormat() wgpu.TextureFormat {
	gpu := js.Global().Get("navigator").Get("gpu")
	if gpu.IsNull() || gpu.IsUndefined() {
		return wgpu.TextureFormatBGRA8Unorm
	}
	switch gpu.Call("getPreferredCanvasFormat").String() {
	case "rgba8unorm":
		return wgpu.TextureFormatRGBA8Unorm
	case "bgra8unorm":
		return wgpu.TextureFormatBGRA8Unorm
	default:
		return wgpu.TextureFormatBGRA8Unorm
	}
}
