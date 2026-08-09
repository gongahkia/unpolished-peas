package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"image"
	"image/color"
	_ "image/png"
	"math"

	"github.com/gongahkia/72/internal/sim"
	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/vector"
)

const (
	playerAtlasColumns = 4
	playerFrameSize    = 64
)

//go:embed assets/player-atlas.png
var playerAtlasPNG []byte

type playerArt struct{ atlas *ebiten.Image }

type playerVisual struct {
	frame          int
	facing         int8
	scaleX, scaleY float64
	offsetY        float64
	tilt           float64
}

func loadPlayerArt() (*playerArt, error) {
	source, _, err := image.Decode(bytes.NewReader(playerAtlasPNG))
	if err != nil {
		return nil, fmt.Errorf("decode player atlas: %w", err)
	}
	return &playerArt{atlas: ebiten.NewImageFromImage(source)}, nil
}

func (art *playerArt) draw(screen *ebiten.Image, player sim.PlayerSnapshot, tick uint64) {
	visual := playerVisualFor(player, tick)
	frame := art.atlas.SubImage(playerFrameRect(visual.frame)).(*ebiten.Image)
	feet := 11.0
	if player.Crouching || player.State == sim.TraversalRolling || player.State == sim.TraversalDiving {
		feet = 7
	}
	shadowRadius := float32(6 * visual.scaleX)
	vector.DrawFilledCircle(screen, float32(player.Pos.X), float32(player.Pos.Y+feet-1), shadowRadius, colorShadow, true)
	drawPlayerMotionAccent(screen, player, visual, feet)

	op := &ebiten.DrawImageOptions{}
	op.Filter = ebiten.FilterNearest
	op.GeoM.Translate(-playerFrameSize/2, -52)
	scaleX := visual.scaleX
	if visual.facing < 0 {
		scaleX = -scaleX
		visual.tilt = -visual.tilt
	}
	op.GeoM.Scale(scaleX, visual.scaleY)
	op.GeoM.Rotate(visual.tilt)
	op.GeoM.Translate(player.Pos.X, player.Pos.Y+feet+visual.offsetY)
	screen.DrawImage(frame, op)
}

var colorShadow = colorRGBA(5, 8, 14, 112)

func playerFrameRect(frame int) image.Rectangle {
	x := frame % playerAtlasColumns * playerFrameSize
	y := frame / playerAtlasColumns * playerFrameSize
	return image.Rect(x, y, x+playerFrameSize, y+playerFrameSize)
}

func playerVisualFor(player sim.PlayerSnapshot, tick uint64) playerVisual {
	visual := playerVisual{frame: 0, facing: player.Facing, scaleX: .56, scaleY: .56}
	if visual.facing == 0 {
		visual.facing = 1
	}
	switch player.State {
	case sim.TraversalRolling:
		visual.frame, visual.scaleX, visual.scaleY, visual.tilt = 8, .61, .50, -.13
	case sim.TraversalWallCling:
		visual.frame, visual.facing, visual.scaleX, visual.scaleY, visual.offsetY = 10, player.WallDirection, .55, .58, bob(tick, 14, 1.2)
	case sim.TraversalClimbing:
		visual.frame, visual.scaleX, visual.scaleY, visual.offsetY = alternatingFrame(tick, 12, 12, 10), .55, .58, bob(tick, 12, 1.4)
	case sim.TraversalDiving:
		visual.frame, visual.scaleX, visual.scaleY = 15, .53, .62
	case sim.TraversalLedgeGrab:
		visual.frame, visual.scaleX, visual.scaleY, visual.offsetY = 13, .54, .58, bob(tick, 16, .8)
	case sim.TraversalMantling:
		visual.frame, visual.scaleX, visual.scaleY, visual.offsetY, visual.tilt = 14, .61, .51, -2, -.08
	case sim.TraversalAirborne:
		switch {
		case player.Velocity.Y < -2 && player.AirJumps == 0:
			visual.frame, visual.scaleX, visual.scaleY, visual.tilt = 7, .60, .53, -.12
		case player.Velocity.Y < -2:
			visual.frame, visual.scaleX, visual.scaleY = alternatingFrame(tick, 8, 4, 5), .51, .62
		case player.Velocity.Y > 2:
			visual.frame, visual.scaleX, visual.scaleY, visual.tilt = 6, .61, .51, .07
		default:
			visual.frame, visual.scaleX, visual.scaleY = 5, .55, .58
		}
	default:
		switch {
		case player.Crouching:
			visual.frame, visual.scaleX, visual.scaleY, visual.offsetY = 9, .60, .49, 1
		case math.Abs(player.Velocity.X) > .45:
			visual.frame = alternatingFrame(tick, 6, 2, 3)
			visual.scaleX, visual.scaleY = .59, .53
			visual.offsetY = bob(tick, 6, .9)
			visual.tilt = -.05
		default:
			visual.frame = alternatingFrame(tick, 36, 0, 1)
			visual.offsetY = bob(tick, 36, .7)
		}
	}
	return visual
}

func alternatingFrame(tick, period uint64, first, second int) int {
	if tick/period%2 == 0 {
		return first
	}
	return second
}

func bob(tick, period uint64, amount float64) float64 {
	return math.Sin(float64(tick%period)/float64(period)*2*math.Pi) * amount
}

func drawPlayerMotionAccent(screen *ebiten.Image, player sim.PlayerSnapshot, visual playerVisual, feet float64) {
	if player.State == sim.TraversalDiving {
		vector.StrokeLine(screen, float32(player.Pos.X-6), float32(player.Pos.Y-20), float32(player.Pos.X-6), float32(player.Pos.Y-7), 1, colorRGBA(246, 103, 120, 180), true)
		vector.StrokeLine(screen, float32(player.Pos.X+6), float32(player.Pos.Y-18), float32(player.Pos.X+6), float32(player.Pos.Y-5), 1, colorRGBA(246, 103, 120, 180), true)
		return
	}
	if player.State != sim.TraversalGrounded || math.Abs(player.Velocity.X) <= 2 {
		return
	}
	direction := float64(visual.facing)
	for index := range 2 {
		x := player.Pos.X - direction*float64(12+index*5)
		vector.StrokeLine(screen, float32(x), float32(player.Pos.Y+feet-5-float64(index*3)), float32(x-direction*5), float32(player.Pos.Y+feet-5-float64(index*3)), 1, colorRGBA(132, 207, 255, 128), true)
	}
}

func colorRGBA(red, green, blue, alpha uint8) color.RGBA {
	return color.RGBA{R: red, G: green, B: blue, A: alpha}
}
