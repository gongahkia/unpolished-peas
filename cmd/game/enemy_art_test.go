package main

import (
	"bytes"
	"image"
	"math"
	"testing"

	"github.com/gongahkia/72/internal/sim"
)

func TestEnemyVisualMapsArchetypesAndStatesToAtlasFrames(t *testing.T) {
	tests := []struct {
		name  string
		enemy sim.EnemySnapshot
		want  int
	}{
		{"charger roam", sim.EnemySnapshot{Archetype: sim.EnemyCharger, State: sim.EnemyRoam}, 0},
		{"charger telegraph", sim.EnemySnapshot{Archetype: sim.EnemyCharger, State: sim.EnemyTelegraph}, 2},
		{"charger charge", sim.EnemySnapshot{Archetype: sim.EnemyCharger, State: sim.EnemyCharge}, 3},
		{"hopper airborne", sim.EnemySnapshot{Archetype: sim.EnemyHopper}, 6},
		{"hopper windup", sim.EnemySnapshot{Archetype: sim.EnemyHopper, Grounded: true, Timer: 7}, 5},
		{"hopper idle", sim.EnemySnapshot{Archetype: sim.EnemyHopper, Grounded: true, Timer: 30}, 4},
		{"diver telegraph", sim.EnemySnapshot{Archetype: sim.EnemyDiver, State: sim.EnemyTelegraph}, 9},
		{"diver dive", sim.EnemySnapshot{Archetype: sim.EnemyDiver, State: sim.EnemyDive}, 10},
		{"diver stunned", sim.EnemySnapshot{Archetype: sim.EnemyDiver, State: sim.EnemyStunned}, 11},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := enemyVisualFor(test.enemy, 0).frame; got != test.want {
				t.Fatalf("selected frame %d, want %d", got, test.want)
			}
		})
	}
}

func TestDiverVisualRotatesTowardDiveVelocity(t *testing.T) {
	visual := enemyVisualFor(sim.EnemySnapshot{
		Archetype: sim.EnemyDiver,
		State:     sim.EnemyDive,
		Velocity:  sim.Vec{X: 6},
	}, 0)
	if got, want := visual.tilt, -math.Pi/2; math.Abs(got-want) > .00001 {
		t.Fatalf("rightward dive tilt = %f, want %f", got, want)
	}
}

func TestEnemyAtlasUsesTheExpectedFourByFourGrid(t *testing.T) {
	atlas, _, err := image.Decode(bytes.NewReader(enemyAtlasPNG))
	if err != nil {
		t.Fatalf("decode embedded enemy atlas: %v", err)
	}
	if got, want := atlas.Bounds().Dx(), textureAtlasColumns*textureAtlasFrame; got != want {
		t.Fatalf("atlas width = %d, want %d", got, want)
	}
	if got, want := atlas.Bounds().Dy(), textureAtlasRows*textureAtlasFrame; got != want {
		t.Fatalf("atlas height = %d, want %d", got, want)
	}
	if _, _, _, alpha := atlas.At(0, 0).RGBA(); alpha != 0 {
		t.Fatalf("atlas corner is opaque: alpha = %d", alpha)
	}
}
