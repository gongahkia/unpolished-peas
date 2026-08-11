package assets

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"io"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/gongahkia/72/engine/diagnostics"
	"github.com/gongahkia/72/engine/render"
	"golang.org/x/image/font/gofont/goregular"
)

func stringLoader(_ string, source io.Reader) (string, error) {
	bytes, err := io.ReadAll(source)
	return string(bytes), err
}

func TestManagerLoadsReloadsAndBuildsManifest(t *testing.T) {
	manager := NewManager(fstest.MapFS{"greeting.txt": {Data: []byte("hello")}, "other.txt": {Data: []byte("other")}})
	handle, err := Load(manager, "greeting.txt", stringLoader)
	if err != nil {
		t.Fatal(err)
	}
	if value, ok := Get(manager, handle); !ok || value != "hello" {
		t.Fatalf("loaded asset = %q, %t", value, ok)
	}
	other, err := Load(manager, "other.txt", stringLoader)
	if err != nil {
		t.Fatal(err)
	}
	if err := SetDependencies(manager, handle, other.AssetID()); err != nil {
		t.Fatal(err)
	}
	called := false
	if err := OnReload(manager, handle, func() { called = true }); err != nil {
		t.Fatal(err)
	}
	if err := Reload(manager, handle, func(_ string, _ io.Reader) (string, error) { return "updated", nil }); err != nil {
		t.Fatal(err)
	}
	if value, _ := Get(manager, handle); value != "updated" || !called {
		t.Fatalf("reloaded asset = %q callback=%t", value, called)
	}
	manifest := manager.Manifest()
	if len(manifest) != 2 || manifest[0].Path != "greeting.txt" || len(manifest[0].Dependencies) != 1 {
		t.Fatalf("manifest = %+v", manifest)
	}
	if _, err := Load(manager, "../outside", stringLoader); err == nil || !strings.Contains(err.Error(), "project-relative") {
		t.Fatalf("invalid path error = %v", err)
	}
}

func TestLoadReportsStructuredAssetFailure(t *testing.T) {
	_, err := Load(NewManager(fstest.MapFS{}), "missing.txt", stringLoader)
	var failure *diagnostics.Failure
	if !errors.As(err, &failure) {
		t.Fatalf("load error %v is not a diagnostics failure", err)
	}
	if failure.Subsystem != diagnostics.AssetsSubsystem || failure.Operation != "load asset" || failure.Recovery != diagnostics.CorrectInput || failure.Terminal {
		t.Fatalf("failure = %+v", failure)
	}
}

func TestStandardLoadersDecodePortableAssetsAndTrackTileDependencies(t *testing.T) {
	manager := NewManager(fstest.MapFS{
		"tiles.png":        {Data: pngData(t)},
		"font.ttf":         {Data: goregular.TTF},
		"sound.wav":        {Data: wav16(0, 16_384, -16_384)},
		"world.tiles.json": {Data: []byte(`{"texture":"tiles.png","width":2,"height":1,"atlasWidth":32,"atlasHeight":16,"tileWidth":16,"tileHeight":16,"tiles":[0,-1]}`)},
	})
	texture, err := Load(manager, "tiles.png", DecodeImage)
	if err != nil {
		t.Fatalf("load image: %v", err)
	}
	if image, ok := Get(manager, texture); !ok || image.Width != 2 || image.Height != 1 || image.Pixels[0] != 20 {
		t.Fatalf("portable image = %+v, loaded=%t", image, ok)
	}
	font, err := Load(manager, "font.ttf", DecodeFont)
	if err != nil {
		t.Fatalf("load font: %v", err)
	}
	loadedFont, ok := Get(manager, font)
	if !ok || len(loadedFont.Bytes()) != len(goregular.TTF) {
		t.Fatalf("font = %d bytes, loaded=%t", len(loadedFont.Bytes()), ok)
	}
	fontBytes := loadedFont.Bytes()
	fontBytes[0] ^= 0xff
	if again, _ := Get(manager, font); again.Bytes()[0] != goregular.TTF[0] {
		t.Fatal("font bytes leaked mutable ownership")
	}
	sound, err := Load(manager, "sound.wav", DecodeWAV)
	if err != nil {
		t.Fatalf("load WAV: %v", err)
	}
	loadedSound, ok := Get(manager, sound)
	if !ok || !loadedSound.Audio().Valid() || loadedSound.SampleRate() != 48_000 || loadedSound.Samples()[1] != .5 || loadedSound.Samples()[2] != -.5 {
		t.Fatalf("portable sound = %+v, loaded=%t", loadedSound, ok)
	}
	soundSamples := loadedSound.Samples()
	soundSamples[0] = 1
	if again, _ := Get(manager, sound); again.Samples()[0] != 0 {
		t.Fatal("sound samples leaked mutable ownership")
	}
	tiles, err := LoadTileMap(manager, "world.tiles.json", texture)
	if err != nil {
		t.Fatalf("load tile map: %v", err)
	}
	loadedTiles, ok := Get(manager, tiles)
	if !ok {
		t.Fatal("tile map was not loaded")
	}
	command, err := loadedTiles.Render(render.Texture{ID: 1}, render.Vec2{X: 8, Y: 12})
	if err != nil {
		t.Fatalf("render tile map: %v", err)
	}
	if command.Columns != 2 || command.Bounds.X != 8 || command.Bounds.H != 16 || command.Tiles[1] != -1 {
		t.Fatalf("tile-map command = %+v", command)
	}
	manifest := manager.Manifest()
	if len(manifest) != 4 || len(manifest[3].Dependencies) != 1 || manifest[3].Dependencies[0] != texture.AssetID() {
		t.Fatalf("manifest dependencies = %+v", manifest)
	}
}

func TestStandardLoadersRejectMalformedInput(t *testing.T) {
	if _, err := DecodeImage("bad.png", strings.NewReader("not an image")); err == nil {
		t.Fatal("malformed image decoded")
	}
	if _, err := DecodeFont("bad.ttf", strings.NewReader("not a font")); err == nil {
		t.Fatal("malformed font decoded")
	}
	if _, err := DecodeWAV("bad.wav", strings.NewReader("RIFF")); err == nil {
		t.Fatal("malformed WAV decoded")
	}
	if _, err := DecodeTileMap("bad.tiles.json", strings.NewReader(`{"texture":"../tiles.png","width":1,"height":1,"atlasWidth":16,"atlasHeight":16,"tileWidth":16,"tileHeight":16,"tiles":[1]}`)); err == nil {
		t.Fatal("invalid tile map decoded")
	}
}

func TestProjectManifestBuildsAReproduciblePackage(t *testing.T) {
	manifestData := []byte(`{
  "version": 1,
  "name": "minimal",
  "assets": [
    {"path":"world.tiles.json","type":"tile-map","mode":"embed","dependencies":["tiles.png"]},
    {"path":"sound.wav","type":"audio","mode":"external"},
    {"path":"tiles.png","type":"image","mode":"embed"}
  ]
}`)
	source := fstest.MapFS{
		"72.assets.json":   {Data: manifestData},
		"tiles.png":        {Data: pngData(t)},
		"sound.wav":        {Data: wav16(0, 16_384)},
		"world.tiles.json": {Data: []byte(`{"texture":"tiles.png","width":2,"height":1,"atlasWidth":32,"atlasHeight":16,"tileWidth":16,"tileHeight":16,"tiles":[0,-1]}`)},
	}
	manifest, err := LoadProjectManifest(source, "72.assets.json")
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	first, err := BuildPackage(source, manifest)
	if err != nil {
		t.Fatalf("build package: %v", err)
	}
	reordered := manifest
	reordered.Assets[0], reordered.Assets[2] = reordered.Assets[2], reordered.Assets[0]
	second, err := BuildPackage(source, reordered)
	if err != nil {
		t.Fatalf("build reordered package: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatalf("repeated package bytes differ:\n%s\n%s", first, second)
	}
	var built Package
	if err := json.Unmarshal(first, &built); err != nil {
		t.Fatalf("decode package: %v", err)
	}
	if built.Version != PackageVersion || built.Name != "minimal" || len(built.Assets) != 3 || built.Assets[0].Path != "sound.wav" || built.Assets[0].Mode != ExternalAsset || len(built.Assets[0].Data) != 0 || len(built.Assets[0].SHA256) != 64 {
		t.Fatalf("package = %+v", built)
	}
	if built.Assets[2].Path != "world.tiles.json" || len(built.Assets[2].Dependencies) != 1 || built.Assets[2].Dependencies[0] != "tiles.png" || len(built.Assets[2].Data) == 0 {
		t.Fatalf("embedded tile package = %+v", built.Assets[2])
	}
}

func TestProjectManifestRejectsInvalidPathsDuplicatesAndMissingAssets(t *testing.T) {
	source := fstest.MapFS{"tiles.png": {Data: pngData(t)}}
	base := ProjectManifest{Version: PackageVersion, Name: "test", Assets: []ManifestAsset{{Path: "tiles.png", Type: AssetImage, Mode: EmbedAsset}}}
	if _, err := BuildPackage(source, ProjectManifest{Version: PackageVersion, Name: "test", Assets: []ManifestAsset{{Path: "../tiles.png", Type: AssetImage, Mode: EmbedAsset}}}); err == nil || !strings.Contains(err.Error(), "project-relative") {
		t.Fatalf("invalid manifest path error = %v", err)
	}
	duplicate := base
	duplicate.Assets = append(duplicate.Assets, duplicate.Assets[0])
	if _, err := BuildPackage(source, duplicate); err == nil || !strings.Contains(err.Error(), "more than once") {
		t.Fatalf("duplicate manifest path error = %v", err)
	}
	missing := base
	missing.Assets[0].Path = "missing.png"
	if _, err := BuildPackage(source, missing); err == nil || !strings.Contains(err.Error(), `package asset "missing.png": open source`) {
		t.Fatalf("missing source error = %v", err)
	}
}

func pngData(t *testing.T) []byte {
	t.Helper()
	image := image.NewNRGBA(image.Rect(0, 0, 2, 1))
	image.SetNRGBA(0, 0, color.NRGBA{R: 20, G: 40, B: 60, A: 255})
	image.SetNRGBA(1, 0, color.NRGBA{R: 80, G: 100, B: 120, A: 128})
	var data bytes.Buffer
	if err := png.Encode(&data, image); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}

func wav16(samples ...int16) []byte {
	data := make([]byte, 44+len(samples)*2)
	copy(data[0:4], "RIFF")
	binary.LittleEndian.PutUint32(data[4:8], uint32(len(data)-8))
	copy(data[8:12], "WAVE")
	copy(data[12:16], "fmt ")
	binary.LittleEndian.PutUint32(data[16:20], 16)
	binary.LittleEndian.PutUint16(data[20:22], 1)
	binary.LittleEndian.PutUint16(data[22:24], 1)
	binary.LittleEndian.PutUint32(data[24:28], 48_000)
	binary.LittleEndian.PutUint32(data[28:32], 96_000)
	binary.LittleEndian.PutUint16(data[32:34], 2)
	binary.LittleEndian.PutUint16(data[34:36], 16)
	copy(data[36:40], "data")
	binary.LittleEndian.PutUint32(data[40:44], uint32(len(samples)*2))
	for index, sample := range samples {
		binary.LittleEndian.PutUint16(data[44+index*2:], uint16(sample))
	}
	return data
}
