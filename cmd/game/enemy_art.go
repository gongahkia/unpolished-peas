package main

import (
	_ "embed"
	"math"

	"github.com/gongahkia/72/internal/sim"
	"github.com/hajimehoshi/ebiten/v2"
)

//go:embed assets/enemy-atlas.png
var enemyAtlasPNG []byte

type enemyArt struct{ atlas textureAtlas }

type enemyVisual struct {
	frame          int
	facing         int8
	scaleX, scaleY float64
	offsetY        float64
	tilt           float64
}

func loadEnemyArt() (*enemyArt, error) {
	atlas, err := loadTextureAtlas(enemyAtlasPNG, "enemy")
	if err != nil {
		return nil, err
	}
	return &enemyArt{atlas: atlas}, nil
}

func (art *enemyArt) draw(screen *ebiten.Image, enemy sim.EnemySnapshot, tick uint64) {
	visual := enemyVisualFor(enemy, tick)
	frame := art.atlas.frame(visual.frame)

	op := &ebiten.DrawImageOptions{}
	op.Filter = ebiten.FilterNearest
	op.GeoM.Translate(-textureAtlasFrame/2, -textureAtlasFrame/2)
	scaleX := visual.scaleX
	if visual.facing < 0 {
		scaleX = -scaleX
		visual.tilt = -visual.tilt
	}
	op.GeoM.Scale(scaleX, visual.scaleY)
	op.GeoM.Rotate(visual.tilt)
	op.GeoM.Translate(enemy.Pos.X, enemy.Pos.Y+visual.offsetY)
	screen.DrawImage(frame, op)
}

func enemyVisualFor(enemy sim.EnemySnapshot, tick uint64) enemyVisual {
	visual := enemyVisual{facing: enemy.Facing, scaleX: .6, scaleY: .6}
	if visual.facing == 0 {
		visual.facing = 1
	}
	switch enemy.Archetype {
	case sim.EnemyHopper:
		visual.scaleX, visual.scaleY = .66, .66
		switch {
		case !enemy.Grounded:
			visual.frame, visual.offsetY = 6, bob(tick, 12, .8)
		case enemy.Timer < 8:
			visual.frame, visual.scaleX, visual.scaleY = 5, .72, .53
		case enemy.Timer > 46:
			visual.frame, visual.scaleX, visual.scaleY = 7, .72, .55
		default:
			visual.frame, visual.offsetY = 4, bob(tick, 28, .45)
		}
	case sim.EnemyDiver:
		visual.scaleX, visual.scaleY = .62, .62
		switch enemy.State {
		case sim.EnemyTelegraph:
			visual.frame, visual.scaleX, visual.scaleY = 9, .66, .58
		case sim.EnemyDive:
			visual.frame, visual.facing, visual.scaleX, visual.scaleY = 10, 1, .58, .68
			if enemy.Velocity.LengthSq() > 0 {
				visual.tilt = math.Atan2(enemy.Velocity.Y, enemy.Velocity.X) - math.Pi/2
			}
		case sim.EnemyStunned:
			visual.frame, visual.offsetY = 11, bob(tick, 10, .7)
		default:
			visual.frame, visual.offsetY = 8, bob(tick, 30, .45)
		}
	default:
		switch enemy.State {
		case sim.EnemyTelegraph:
			visual.frame, visual.scaleX, visual.scaleY = 2, .64, .56
		case sim.EnemyCharge:
			visual.frame, visual.scaleX, visual.scaleY = 3, .72, .52
		case sim.EnemyRecover, sim.EnemyStunned:
			visual.frame, visual.scaleX, visual.scaleY = 1, .58, .62
		default:
			visual.frame = alternatingFrame(tick, 10, 0, 1)
		}
	}
	return visual
}
