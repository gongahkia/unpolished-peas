package main

import (
	"image/color"
	"math"

	"github.com/gongahkia/72/internal/sim"
	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/vector"
)

const (
	deepBackgroundDepth = .16
	backgroundDepth     = .44
	foregroundDepth     = 1.08
)

func drawEnvironment(screen *ebiten.Image, seed uint64, camera sim.Vec, tick uint64, shake float64) {
	screen.Fill(color.RGBA{R: 8, G: 10, B: 15, A: 255})
	drawDeepBackground(screen, seed, camera, tick, shake)
	drawBackground(screen, seed, camera, shake)
}

func drawDeepBackground(screen *ebiten.Image, seed uint64, camera sim.Vec, tick uint64, shake float64) {
	const spacing = 80.0
	first, last := visibleLayerColumns(camera.X, deepBackgroundDepth, spacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 1)
		x := layerPosition(float64(column)*spacing, camera.X, deepBackgroundDepth) + shake*.08
		y := 18 + environmentUnit(hash, 2)*250 - camera.Y*deepBackgroundDepth
		size := float32(1 + hash%2)
		alpha := uint8(36 + hash>>8%44)
		if hash>>16%5 == uint64(tick/18%5) {
			alpha += 34
		}
		vector.DrawFilledRect(screen, float32(x), float32(y), size, size, color.RGBA{R: 120, G: 166, B: 207, A: alpha}, false)
	}

	const glowSpacing = 356.0
	first, last = visibleLayerColumns(camera.X, deepBackgroundDepth, glowSpacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 3)
		x := layerPosition(float64(column)*glowSpacing+environmentUnit(hash, 4)*90, camera.X, deepBackgroundDepth) + shake*.05
		y := 74 + environmentUnit(hash, 5)*104 - camera.Y*deepBackgroundDepth
		radius := float32(20 + hash>>12%24)
		vector.DrawFilledCircle(screen, float32(x), float32(y), radius, color.RGBA{R: 27, G: 43, B: 69, A: 150}, true)
		vector.DrawFilledCircle(screen, float32(x), float32(y), radius*.62, color.RGBA{R: 42, G: 62, B: 93, A: 120}, true)
	}
}

func drawBackground(screen *ebiten.Image, seed uint64, camera sim.Vec, shake float64) {
	const spacing = 104.0
	first, last := visibleLayerColumns(camera.X, backgroundDepth, spacing)
	groundY := float64(logicalH) - camera.Y*backgroundDepth + shake*.2
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 7)
		x := layerPosition(float64(column)*spacing, camera.X, backgroundDepth) + shake*.2
		width := 68 + environmentUnit(hash, 8)*42
		height := 88 + environmentUnit(hash, 9)*132
		bounds := sim.Rect{X: x, Y: groundY - height, W: width, H: height}
		vector.DrawFilledRect(screen, float32(bounds.X), float32(bounds.Y), float32(bounds.W), float32(bounds.H), color.RGBA{R: 17, G: 27, B: 43, A: 235}, false)
		vector.DrawFilledRect(screen, float32(bounds.X+8), float32(bounds.Y+10), float32(bounds.W-16), 4, color.RGBA{R: 45, G: 65, B: 86, A: 170}, false)

		for row := 0; row < int(height/30); row++ {
			if environmentHash(seed, uint64(column), uint64(row)+10)%3 == 0 {
				continue
			}
			windowX := bounds.X + 13 + environmentUnit(hash, uint64(row)+20)*(bounds.W-30)
			windowY := bounds.Y + 24 + float64(row)*28
			vector.DrawFilledRect(screen, float32(windowX), float32(windowY), 4, 7, color.RGBA{R: 101, G: 157, B: 172, A: 125}, false)
		}
	}
}

func drawForeground(screen *ebiten.Image, seed uint64, camera sim.Vec, shake float64) {
	const spacing = 94.0
	first, last := visibleLayerColumns(camera.X, foregroundDepth, spacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 30)
		x := layerPosition(float64(column)*spacing, camera.X, foregroundDepth) + shake*.9
		width := 14 + environmentUnit(hash, 31)*24
		height := 18 + environmentUnit(hash, 32)*42
		y := float64(logicalH) - height - camera.Y*(foregroundDepth-1)*.12
		vector.DrawFilledRect(screen, float32(x), float32(y), float32(width), float32(height), color.RGBA{R: 8, G: 14, B: 22, A: 148}, false)
		vector.StrokeLine(screen, float32(x+width*.5), float32(y), float32(x+width*.5+environmentUnit(hash, 33)*10-5), float32(y-height*.42), 2, color.RGBA{R: 44, G: 80, B: 91, A: 110}, true)
	}

	const fringeSpacing = 160.0
	first, last = visibleLayerColumns(camera.X, foregroundDepth, fringeSpacing)
	for column := first; column <= last; column++ {
		hash := environmentHash(seed, uint64(column), 40)
		x := layerPosition(float64(column)*fringeSpacing, camera.X, foregroundDepth) + shake*.9
		height := 18 + environmentUnit(hash, 41)*38
		vector.DrawFilledRect(screen, float32(x), 0, float32(12+hash%15), float32(height), color.RGBA{R: 7, G: 12, B: 19, A: 140}, false)
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
