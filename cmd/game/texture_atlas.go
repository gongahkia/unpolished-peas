package main

import (
	"bytes"
	"fmt"
	"image"

	"github.com/hajimehoshi/ebiten/v2"
)

const (
	textureAtlasColumns = 4
	textureAtlasRows    = 4
	textureAtlasFrame   = 64
)

type textureAtlas struct{ image *ebiten.Image }

func loadTextureAtlas(png []byte, name string) (textureAtlas, error) {
	source, _, err := image.Decode(bytes.NewReader(png))
	if err != nil {
		return textureAtlas{}, fmt.Errorf("decode %s atlas: %w", name, err)
	}
	if got, want := source.Bounds().Dx(), textureAtlasColumns*textureAtlasFrame; got != want {
		return textureAtlas{}, fmt.Errorf("%s atlas width = %d, want %d", name, got, want)
	}
	if got, want := source.Bounds().Dy(), textureAtlasRows*textureAtlasFrame; got != want {
		return textureAtlas{}, fmt.Errorf("%s atlas height = %d, want %d", name, got, want)
	}
	return textureAtlas{image: ebiten.NewImageFromImage(source)}, nil
}

func (atlas textureAtlas) frame(index int) *ebiten.Image {
	return atlas.image.SubImage(textureAtlasFrameRect(index)).(*ebiten.Image)
}

func textureAtlasFrameRect(index int) image.Rectangle {
	x := index % textureAtlasColumns * textureAtlasFrame
	y := index / textureAtlasColumns * textureAtlasFrame
	return image.Rect(x, y, x+textureAtlasFrame, y+textureAtlasFrame)
}
