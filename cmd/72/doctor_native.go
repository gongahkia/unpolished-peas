//go:build !(js && wasm)

package main

import (
	"io"

	"github.com/gongahkia/72/engine/render/webgpu"
)

func runDoctor(arguments []string, stdout, stderr io.Writer) error {
	return runDoctorWithProbe(arguments, stdout, stderr, func() error {
		renderer, err := webgpu.NewHeadless(1, 1)
		if err != nil {
			return err
		}
		renderer.Close()
		return nil
	})
}
