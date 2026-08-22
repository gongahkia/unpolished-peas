//go:build js && wasm

package main

import "syscall/js"

func setAudioStatus(value string) {
	document := js.Global().Get("document")
	status := document.Call("getElementById", "audio-status")
	if !status.IsNull() && !status.IsUndefined() {
		status.Set("textContent", value)
	}
}
