//go:build js && wasm

package main

import (
	"errors"
	"io"
)

func runDoctor(arguments []string, stdout, stderr io.Writer) error {
	return runDoctorWithProbe(arguments, stdout, stderr, func() error {
		return errors.New("WebGPU doctor probe is unavailable in a command WebAssembly build")
	})
}
