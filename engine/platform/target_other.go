//go:build !linux && !(js && wasm)

package platform

import "runtime"

func runtimeTarget() string { return runtime.GOOS + "/" + runtime.GOARCH }
