//go:build !js || !wasm

package main

import "fmt"

func main() {
	fmt.Println("webgpu-browser must be built with GOOS=js GOARCH=wasm")
}
