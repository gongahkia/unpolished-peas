//go:build !linux && !windows && !darwin && !(js && wasm)

package platform

import "runtime"

func runtimeTarget() string { return runtime.GOOS + "/" + runtime.GOARCH }
