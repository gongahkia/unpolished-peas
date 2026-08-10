package main

import (
	"math"

	"github.com/gongahkia/72/engine"
)

const (
	deepBackgroundDepth = .16
	backgroundDepth     = .44
	foregroundDepth     = 1.08
)

func (g *wukongGame) drawDeepBackground(frame engine.Frame) {
	canvas := frame.Canvas
	canvas.Clear(engine.Color{R: 8, G: 10, B: 15, A: 255})
	seed := g.snapshot.Seed
	const spacing = 80.0
	first, last := visibleLayerColumns(frame.Camera.Position().X, deepBackgroundDepth, spacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 1)
		x := float64(column) * spacing
		y := 18 + environmentUnit(hash, 2)*250
		size := 1 + float64(hash%2)
		alpha := uint8(36 + hash>>8%44)
		if hash>>16%5 == uint64(g.snapshot.Tick/18%5) {
			alpha += 34
		}
		canvas.FillRect(engine.Rect{X: x, Y: y, W: size, H: size}, engine.Color{R: 120, G: 166, B: 207, A: alpha})
	}

	const glowSpacing = 356.0
	first, last = visibleLayerColumns(frame.Camera.Position().X, deepBackgroundDepth, glowSpacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 3)
		x := float64(column)*glowSpacing + environmentUnit(hash, 4)*90
		y := 74 + environmentUnit(hash, 5)*104
		radius := 20 + float64(hash>>12%24)
		canvas.FillCircle(engine.Vec2{X: x, Y: y}, radius, engine.Color{R: 27, G: 43, B: 69, A: 150})
		canvas.FillCircle(engine.Vec2{X: x, Y: y}, radius*.62, engine.Color{R: 42, G: 62, B: 93, A: 120})
	}
}

func (g *wukongGame) drawBackground(frame engine.Frame) {
	canvas := frame.Canvas
	seed := g.snapshot.Seed
	const spacing = 104.0
	first, last := visibleLayerColumns(frame.Camera.Position().X, backgroundDepth, spacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 7)
		width := 68 + environmentUnit(hash, 8)*42
		height := 88 + environmentUnit(hash, 9)*132
		bounds := engine.Rect{X: float64(column) * spacing, Y: float64(logicalH) - height, W: width, H: height}
		canvas.FillRect(bounds, engine.Color{R: 17, G: 27, B: 43, A: 235})
		canvas.FillRect(engine.Rect{X: bounds.X + 8, Y: bounds.Y + 10, W: bounds.W - 16, H: 4}, engine.Color{R: 45, G: 65, B: 86, A: 170})

		for row := 0; row < int(height/30); row++ {
			if environmentHash(seed, uint64(column), uint64(row)+10)%3 == 0 {
				continue
			}
			windowX := bounds.X + 13 + environmentUnit(hash, uint64(row)+20)*(bounds.W-30)
			windowY := bounds.Y + 24 + float64(row)*28
			canvas.FillRect(engine.Rect{X: windowX, Y: windowY, W: 4, H: 7}, engine.Color{R: 101, G: 157, B: 172, A: 125})
		}
	}
}

func (g *wukongGame) drawForeground(frame engine.Frame) {
	canvas := frame.Canvas
	seed := g.snapshot.Seed
	camera := frame.Camera
	shake := camera.Offset()
	const spacing = 94.0
	first, last := visibleLayerColumns(camera.Position().X, foregroundDepth, spacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 30)
		x := layerPosition(float64(column)*spacing, camera.Position().X, foregroundDepth) + shake.X*.9
		width := 14 + environmentUnit(hash, 31)*24
		height := 18 + environmentUnit(hash, 32)*42
		y := float64(logicalH) - height - camera.Position().Y*(foregroundDepth-1)*.12 + shake.Y*.9
		canvas.FillRect(engine.Rect{X: x, Y: y, W: width, H: height}, engine.Color{R: 8, G: 14, B: 22, A: 148})
		canvas.StrokeLine(engine.Vec2{X: x + width*.5, Y: y}, engine.Vec2{X: x + width*.5 + environmentUnit(hash, 33)*10 - 5, Y: y - height*.42}, 2, engine.Color{R: 44, G: 80, B: 91, A: 110})
	}

	const fringeSpacing = 160.0
	first, last = visibleLayerColumns(camera.Position().X, foregroundDepth, fringeSpacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 40)
		x := layerPosition(float64(column)*fringeSpacing, camera.Position().X, foregroundDepth) + shake.X*.9
		height := 18 + environmentUnit(hash, 41)*38
		canvas.FillRect(engine.Rect{X: x, Y: shake.Y * .9, W: 12 + float64(hash%15), H: height}, engine.Color{R: 7, G: 12, B: 19, A: 140})
	}
}

func visibleLayerColumns(cameraX, depth, spacing float64) (int, int) {
	first := int(math.Floor(cameraX*depth/spacing)) - 1
	last := int(math.Ceil((cameraX*depth+float64(logicalW))/spacing)) + 1
	return first, last
}

func layerPosition(worldX, cameraX, depth float64) float64 {
	return worldX - cameraX*depth
}

func environmentUnit(hash uint64, salt uint64) float64 {
	return float64(environmentHash(hash, salt, 0)>>11) / (1 << 53)
}

func environmentHash(seed, value, salt uint64) uint64 {
	hash := seed + 0x9e3779b97f4a7c15 + value*0xbf58476d1ce4e5b9 + salt*0x94d049bb133111eb
	hash ^= hash >> 30
	hash *= 0xbf58476d1ce4e5b9
	hash ^= hash >> 27
	hash *= 0x94d049bb133111eb
	return hash ^ hash>>31
}
