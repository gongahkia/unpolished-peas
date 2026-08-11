// Command webgpu-native is a disposable native WebGPU presentation spike.
//
// It intentionally lives in its own module so it cannot become an accidental
// engine dependency before the distribution decision is accepted.
package main

import (
	"fmt"
	"log"
	"time"

	"github.com/gogpu/gogpu"
	"github.com/gogpu/gogpu/gmath"
)

func main() {
	started := time.Now()
	app := gogpu.NewApp(gogpu.DefaultConfig().
		WithTitle("72 WebGPU native spike").
		WithSize(960, 540))

	var firstFrame time.Time
	frames := 0
	reportAt := time.Now().Add(time.Second)
	app.OnSurfaceAvailable(func() {
		fmt.Printf("surface available after %s\n", time.Since(started).Round(time.Millisecond))
	})
	app.OnSurfaceDestroyed(func() {
		fmt.Println("surface destroyed")
	})
	app.OnResize(func(width, height int) {
		fmt.Printf("resize: logical=%dx%d\n", width, height)
	})
	app.OnDraw(func(context *gogpu.Context) {
		if firstFrame.IsZero() {
			firstFrame = time.Now()
			fmt.Printf("first frame after %s\n", firstFrame.Sub(started).Round(time.Millisecond))
		}
		if err := context.DrawTriangleColor(gmath.DarkGray); err != nil {
			log.Printf("draw triangle: %v", err)
		}
		frames++
		if now := time.Now(); now.After(reportAt) {
			fmt.Printf("frames in prior second: %d\n", frames)
			frames, reportAt = 0, now.Add(time.Second)
		}
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
	fmt.Println("clean shutdown")
}
