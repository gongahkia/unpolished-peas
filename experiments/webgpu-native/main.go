// Command webgpu-native is a disposable native WebGPU presentation spike.
//
// It intentionally lives in its own module so it cannot become an accidental
// engine dependency before the distribution decision is accepted.
package main

import (
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/gogpu/gogpu"
	"github.com/gogpu/gogpu/gmath"
)

func main() {
	smokeDuration := flag.Duration("smoke-duration", 0, "request a resize halfway through this duration, then exit through App.Quit")
	flag.Parse()

	started := time.Now()
	app := gogpu.NewApp(gogpu.DefaultConfig().
		WithTitle("72 WebGPU native spike").
		WithSize(960, 540))

	var firstFrame time.Time
	frames := 0
	reportAt := time.Now().Add(time.Second)
	var smokeAnimation *gogpu.AnimationToken
	smokeResizeRequested := false
	smokeQuitRequested := false
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
	app.OnUpdate(func(float64) {
		if *smokeDuration <= 0 {
			return
		}
		if smokeAnimation == nil {
			smokeAnimation = app.StartAnimation()
		}
		if smokeQuitRequested {
			return
		}
		elapsed := time.Since(started)
		if !smokeResizeRequested && elapsed >= *smokeDuration/2 {
			smokeResizeRequested = true
			fmt.Println("smoke resize request: logical=800x450")
			app.RequestSize(800, 450)
		}
		if elapsed >= *smokeDuration {
			smokeQuitRequested = true
			fmt.Printf("smoke quit after %s\n", elapsed.Round(time.Millisecond))
			smokeAnimation.Stop()
			app.Quit()
		}
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
	fmt.Println("clean shutdown")
}
