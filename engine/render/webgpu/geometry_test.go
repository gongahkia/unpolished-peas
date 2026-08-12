package webgpu

import (
	"math"
	"testing"

	"github.com/gongahkia/72/engine/render"
)

func TestStrokeCircleVerticesCenterTheStrokeOnTheDeclaredRadius(t *testing.T) {
	vertices, err := primitiveVertices(render.Command{
		Kind: render.StrokeCircle,
		Payload: render.CircleDraw{
			Center: render.Vec2{X: 20, Y: 20}, Radius: 5, Width: 2,
		},
	}, render.Vec2{}, 40, 40)
	if err != nil {
		t.Fatalf("primitiveVertices() error = %v", err)
	}
	minimum, maximum := math.Inf(1), 0.0
	for _, vertex := range vertices {
		point := screenPoint(vertex, 40, 40)
		distance := math.Hypot(point.X-20, point.Y-20)
		minimum = math.Min(minimum, distance)
		maximum = math.Max(maximum, distance)
	}
	if math.Abs(minimum-4) > .001 || math.Abs(maximum-6) > .001 {
		t.Fatalf("stroke radii = %.3f..%.3f, want 4..6", minimum, maximum)
	}
}

func TestStrokeLineVerticesIncludeRoundEndpointCaps(t *testing.T) {
	vertices, err := primitiveVertices(render.Command{
		Kind: render.StrokeLine,
		Payload: render.LineDraw{
			Start: render.Vec2{X: 10, Y: 10}, End: render.Vec2{X: 20, Y: 10}, Width: 4,
		},
	}, render.Vec2{}, 40, 40)
	if err != nil {
		t.Fatalf("primitiveVertices() error = %v", err)
	}
	minimumX, maximumX := math.Inf(1), math.Inf(-1)
	for _, vertex := range vertices {
		point := screenPoint(vertex, 40, 40)
		minimumX = math.Min(minimumX, point.X)
		maximumX = math.Max(maximumX, point.X)
	}
	if math.Abs(minimumX-8) > .001 || math.Abs(maximumX-22) > .001 {
		t.Fatalf("line extent = %.3f..%.3f, want 8..22", minimumX, maximumX)
	}
}

func TestStrokeRectFillsWhenTheStrokeConsumesTheInterior(t *testing.T) {
	vertices, err := primitiveVertices(render.Command{
		Kind:    render.StrokeRect,
		Payload: render.RectDraw{Bounds: render.Rect{X: 1, Y: 1, W: 4, H: 3}, Width: 2},
	}, render.Vec2{}, 8, 8)
	if err != nil {
		t.Fatalf("primitiveVertices() error = %v", err)
	}
	if len(vertices) != 6 {
		t.Fatalf("filled stroke vertex count = %d, want 6", len(vertices))
	}
}

func TestPrimitiveVerticesRejectsDirectNonFiniteCommands(t *testing.T) {
	_, err := primitiveVertices(render.Command{
		Kind:    render.FillCircle,
		Payload: render.CircleDraw{Center: render.Vec2{X: math.NaN()}, Radius: 1},
	}, render.Vec2{}, 8, 8)
	if err == nil {
		t.Fatal("non-finite direct circle command succeeded")
	}
}

func screenPoint(vertex vertex, width, height int) render.Vec2 {
	return render.Vec2{
		X: (float64(vertex.x) + 1) * float64(width) / 2,
		Y: (1 - float64(vertex.y)) * float64(height) / 2,
	}
}
