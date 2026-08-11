//go:build js && wasm

// Command webgpu-browser is a disposable browser WebGPU presentation spike.
// It has no engine imports and is not a production browser host.
package main

import (
	"fmt"
	"math"
	"syscall/js"
)

var (
	document js.Value
	window   js.Value
	canvas   js.Value
	context  js.Value
	device   js.Value
	format   string
	ready    bool
)

func main() {
	document = js.Global().Get("document")
	window = js.Global().Get("window")
	canvas = document.Call("getElementById", "surface")
	if canvas.IsNull() || canvas.IsUndefined() {
		setStatus("fatal: page is missing #surface")
		return
	}

	navigator := js.Global().Get("navigator")
	gpu := navigator.Get("gpu")
	if gpu.IsNull() || gpu.IsUndefined() {
		setStatus("WebGPU is unavailable. Use a supported browser in a secure context.")
		return
	}
	context = canvas.Call("getContext", "webgpu")
	if context.IsNull() || context.IsUndefined() {
		setStatus("WebGPU is present, but this canvas cannot create a WebGPU context.")
		return
	}

	adapter, err := await(gpu.Call("requestAdapter"))
	if err != nil {
		setStatus("adapter request failed: " + err.Error())
		return
	}
	if adapter.IsNull() || adapter.IsUndefined() {
		setStatus("no compatible WebGPU adapter was available")
		return
	}
	device, err = await(adapter.Call("requestDevice"))
	if err != nil {
		setStatus("device request failed: " + err.Error())
		return
	}
	format = gpu.Call("getPreferredCanvasFormat").String()

	resize := js.FuncOf(func(js.Value, []js.Value) any {
		configureSurface()
		return nil
	})
	window.Call("addEventListener", "resize", resize)
	configureSurface()
	ready = true
	setStatus("WebGPU ready; rendering a clear pass")

	go watchDeviceLoss(device.Get("lost"))
	var frame js.Func
	frame = js.FuncOf(func(js.Value, []js.Value) any {
		if ready && !document.Get("hidden").Bool() {
			renderFrame()
		}
		window.Call("requestAnimationFrame", frame)
		return nil
	})
	window.Call("requestAnimationFrame", frame)
	select {}
}

func configureSurface() {
	rect := canvas.Call("getBoundingClientRect")
	dpr := window.Get("devicePixelRatio").Float()
	width := max(1, int(math.Round(rect.Get("width").Float()*dpr)))
	height := max(1, int(math.Round(rect.Get("height").Float()*dpr)))
	canvas.Set("width", width)
	canvas.Set("height", height)
	if !device.IsNull() && !device.IsUndefined() {
		context.Call("configure", map[string]any{
			"device":    device,
			"format":    format,
			"alphaMode": "opaque",
		})
	}
}

func renderFrame() {
	defer func() {
		if recovered := recover(); recovered != nil {
			ready = false
			setStatus(fmt.Sprintf("presentation failed: %v", recovered))
		}
	}()
	encoder := device.Call("createCommandEncoder")
	view := context.Call("getCurrentTexture").Call("createView")
	pass := encoder.Call("beginRenderPass", map[string]any{
		"colorAttachments": []any{map[string]any{
			"view":       view,
			"clearValue": map[string]any{"r": .08, "g": .12, "b": .2, "a": 1},
			"loadOp":     "clear",
			"storeOp":    "store",
		}},
	})
	pass.Call("end")
	device.Get("queue").Call("submit", []any{encoder.Call("finish")})
}

func watchDeviceLoss(promise js.Value) {
	lost, err := await(promise)
	ready = false
	if err != nil {
		setStatus("device-loss notification failed: " + err.Error())
		return
	}
	setStatus("WebGPU device lost: " + jsMessage(lost))
}

func setStatus(message string) {
	status := document.Call("getElementById", "status")
	if !status.IsNull() && !status.IsUndefined() {
		status.Set("textContent", message)
	}
}

type promiseResult struct {
	value js.Value
	err   error
}

func await(promise js.Value) (js.Value, error) {
	done := make(chan promiseResult, 1)
	resolved := js.FuncOf(func(_ js.Value, args []js.Value) any {
		done <- promiseResult{value: args[0]}
		return nil
	})
	rejected := js.FuncOf(func(_ js.Value, args []js.Value) any {
		done <- promiseResult{err: fmt.Errorf("%s", jsMessage(args[0]))}
		return nil
	})
	promise.Call("then", resolved).Call("catch", rejected)
	result := <-done
	resolved.Release()
	rejected.Release()
	return result.value, result.err
}

func jsMessage(value js.Value) string {
	if value.Type() == js.TypeString {
		return value.String()
	}
	message := value.Get("message")
	if !message.IsNull() && !message.IsUndefined() {
		return message.String()
	}
	return value.String()
}
