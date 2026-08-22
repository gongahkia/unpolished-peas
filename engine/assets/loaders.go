package assets

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/draw"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"io/fs"
	"math"

	"github.com/gongahkia/72/engine/audio"
	"github.com/gongahkia/72/engine/render"
	"golang.org/x/image/font/sfnt"
)

const (
	maxDecodedAssetBytes = 64 << 20
	maxImagePixels       = 16_777_216
)

// Font is validated OpenType or TrueType source data. Bytes returns a copy so
// callers cannot mutate the asset's retained data.
type Font struct{ bytes []byte }

// Bytes returns a copy of the font's encoded source data.
func (f Font) Bytes() []byte { return append([]byte(nil), f.bytes...) }

// Sound is decoded portable PCM data. Samples returns a copy; Audio returns a
// fresh engine/audio value suitable for Mixer.Play.
type Sound struct {
	samples    []float32
	sampleRate int
	channels   int
}

// SampleRate returns the PCM sample rate in hertz.
func (s Sound) SampleRate() int { return s.sampleRate }

// Channels returns the interleaved PCM channel count.
func (s Sound) Channels() int { return s.channels }

// Samples returns a copy of normalized interleaved PCM samples.
func (s Sound) Samples() []float32 { return append([]float32(nil), s.samples...) }

// Audio converts Sound to a fresh portable audio playback value.
func (s Sound) Audio() audio.Sound {
	return audio.Sound{Samples: s.Samples(), SampleRate: s.sampleRate, Channels: s.channels}
}

// TileMap is a portable, finite tile-grid asset. Texture names a project-
// relative image asset; use LoadTileMap to record that manifest dependency.
type TileMap struct {
	Texture     string `json:"texture"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
	AtlasWidth  int    `json:"atlasWidth"`
	AtlasHeight int    `json:"atlasHeight"`
	TileWidth   int    `json:"tileWidth"`
	TileHeight  int    `json:"tileHeight"`
	Tiles       []int  `json:"tiles"`
}

// DecodeImage decodes PNG, JPEG, or GIF into portable, non-premultiplied
// RGBA8 pixels. It does not retain the source reader or any backend image.
func DecodeImage(path string, source io.Reader) (render.Image, error) {
	data, err := readAsset(path, source)
	if err != nil {
		return render.Image{}, err
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return render.Image{}, fmt.Errorf("decode image %q: %w", path, err)
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width > maxImagePixels/config.Height {
		return render.Image{}, fmt.Errorf("decode image %q: dimensions %dx%d exceed the portable image limit", path, config.Width, config.Height)
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return render.Image{}, fmt.Errorf("decode image %q: %w", path, err)
	}
	bounds := decoded.Bounds()
	rgba := image.NewNRGBA(image.Rect(0, 0, bounds.Dx(), bounds.Dy()))
	draw.Draw(rgba, rgba.Bounds(), decoded, bounds.Min, draw.Src)
	portable, err := render.NewImage(bounds.Dx(), bounds.Dy(), rgba.Pix)
	if err != nil {
		return render.Image{}, fmt.Errorf("decode image %q: %w", path, err)
	}
	return portable, nil
}

// DecodeFont validates and copies an OpenType or TrueType font. It does not
// create glyphs or retain an sfnt parser, leaving rasterization to the renderer.
func DecodeFont(path string, source io.Reader) (Font, error) {
	data, err := readAsset(path, source)
	if err != nil {
		return Font{}, err
	}
	if _, err := sfnt.Parse(data); err != nil {
		return Font{}, fmt.Errorf("decode font %q: %w", path, err)
	}
	return Font{bytes: data}, nil
}

// DecodeWAV decodes uncompressed PCM (8/16/24/32-bit) and IEEE float32 WAV
// files to portable interleaved audio samples. Other audio formats belong to a
// future decoder rather than an implicit platform dependency.
func DecodeWAV(path string, source io.Reader) (Sound, error) {
	data, err := readAsset(path, source)
	if err != nil {
		return Sound{}, err
	}
	if len(data) < 12 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return Sound{}, fmt.Errorf("decode WAV %q: missing RIFF/WAVE header", path)
	}
	limit := int(binary.LittleEndian.Uint32(data[4:8])) + 8
	if limit < 12 || limit > len(data) {
		return Sound{}, fmt.Errorf("decode WAV %q: truncated RIFF payload", path)
	}
	var format wavFormat
	var samples []byte
	for offset := 12; offset < limit; {
		if offset+8 > limit {
			return Sound{}, fmt.Errorf("decode WAV %q: truncated chunk header", path)
		}
		kind := string(data[offset : offset+4])
		size := int(binary.LittleEndian.Uint32(data[offset+4 : offset+8]))
		offset += 8
		if size < 0 || size > limit-offset {
			return Sound{}, fmt.Errorf("decode WAV %q: truncated %s chunk", path, kind)
		}
		chunk := data[offset : offset+size]
		switch kind {
		case "fmt ":
			if err := format.parse(chunk); err != nil {
				return Sound{}, fmt.Errorf("decode WAV %q: %w", path, err)
			}
		case "data":
			if samples != nil {
				return Sound{}, fmt.Errorf("decode WAV %q: multiple data chunks are unsupported", path)
			}
			samples = append([]byte(nil), chunk...)
		}
		offset += size
		if size%2 != 0 {
			offset++
			if offset > limit {
				return Sound{}, fmt.Errorf("decode WAV %q: truncated chunk padding", path)
			}
		}
	}
	if !format.present {
		return Sound{}, fmt.Errorf("decode WAV %q: missing fmt chunk", path)
	}
	if len(samples) == 0 {
		return Sound{}, fmt.Errorf("decode WAV %q: missing or empty data chunk", path)
	}
	if len(samples)%format.blockAlign != 0 {
		return Sound{}, fmt.Errorf("decode WAV %q: data length is not aligned to frames", path)
	}
	decoded := make([]float32, 0, len(samples)/format.bytesPerSample)
	for offset := 0; offset < len(samples); offset += format.bytesPerSample {
		value, err := format.sample(samples[offset : offset+format.bytesPerSample])
		if err != nil {
			return Sound{}, fmt.Errorf("decode WAV %q: %w", path, err)
		}
		decoded = append(decoded, value)
	}
	sound := Sound{samples: decoded, sampleRate: format.sampleRate, channels: format.channels}
	if !sound.Audio().Valid() {
		return Sound{}, fmt.Errorf("decode WAV %q: decoded audio has an invalid format", path)
	}
	return sound, nil
}

// DecodeTileMap validates the 72 JSON tile-map format. Tiles are row-major
// atlas indices; negative values leave a cell empty.
func DecodeTileMap(path string, source io.Reader) (TileMap, error) {
	data, err := readAsset(path, source)
	if err != nil {
		return TileMap{}, err
	}
	var tiles TileMap
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&tiles); err != nil {
		return TileMap{}, fmt.Errorf("decode tile map %q: %w", path, err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return TileMap{}, fmt.Errorf("decode tile map %q: expected one JSON value", path)
	}
	if err := tiles.validate(); err != nil {
		return TileMap{}, fmt.Errorf("decode tile map %q: %w", path, err)
	}
	return tiles, nil
}

// LoadTileMap loads a tile map and records its texture handle as a manifest
// dependency. The map's Texture field remains the source-level path used by
// project tooling; texture is the runtime dependency used for packaging.
func LoadTileMap(manager *Manager, path string, texture Handle[render.Image]) (Handle[TileMap], error) {
	if texture.AssetID() == 0 {
		return Handle[TileMap]{}, fmt.Errorf("tile map %q requires a loaded texture handle", path)
	}
	handle, err := Load(manager, path, DecodeTileMap)
	if err != nil {
		return Handle[TileMap]{}, err
	}
	if err := SetDependencies(manager, handle, texture.AssetID()); err != nil {
		return Handle[TileMap]{}, fmt.Errorf("tile map %q texture dependency: %w", path, err)
	}
	return handle, nil
}

// Render converts a validated portable tile map into the public render command
// payload. texture remains backend-neutral and origin is measured in logical
// pixels.
func (m TileMap) Render(texture render.Texture, origin render.Vec2) (render.TileMap, error) {
	if err := m.validate(); err != nil {
		return render.TileMap{}, err
	}
	if texture.ID == 0 {
		return render.TileMap{}, fmt.Errorf("tile map texture must not be zero")
	}
	return render.TileMap{
		Texture:  texture,
		Atlas:    render.Vec2{X: float64(m.AtlasWidth), Y: float64(m.AtlasHeight)},
		TileSize: render.Vec2{X: float64(m.TileWidth), Y: float64(m.TileHeight)},
		Columns:  m.Width,
		Tiles:    append([]int(nil), m.Tiles...),
		Bounds: render.Rect{
			X: origin.X,
			Y: origin.Y,
			W: float64(m.Width * m.TileWidth),
			H: float64(m.Height * m.TileHeight),
		},
	}, nil
}

func (m TileMap) validate() error {
	if !validLoadPath(m.Texture) {
		return fmt.Errorf("texture %q must be a project-relative path", m.Texture)
	}
	if m.Width <= 0 || m.Height <= 0 || m.AtlasWidth <= 0 || m.AtlasHeight <= 0 || m.TileWidth <= 0 || m.TileHeight <= 0 {
		return fmt.Errorf("width, height, atlas dimensions, and tile dimensions must be positive")
	}
	if m.AtlasWidth%m.TileWidth != 0 || m.AtlasHeight%m.TileHeight != 0 {
		return fmt.Errorf("atlas dimensions must be divisible by tile dimensions")
	}
	if m.Width > int(^uint(0)>>1)/m.Height || len(m.Tiles) != m.Width*m.Height {
		return fmt.Errorf("tile count is %d, want %d", len(m.Tiles), m.Width*m.Height)
	}
	maxTile := m.AtlasWidth/m.TileWidth*m.AtlasHeight/m.TileHeight - 1
	for index, tile := range m.Tiles {
		if tile < -1 || tile > maxTile {
			return fmt.Errorf("tile %d has atlas index %d outside [-1,%d]", index, tile, maxTile)
		}
	}
	return nil
}

type wavFormat struct {
	present                    bool
	encoding, channels         int
	sampleRate, bytesPerSample int
	bits, blockAlign           int
}

func (f *wavFormat) parse(data []byte) error {
	if f.present {
		return fmt.Errorf("multiple fmt chunks are unsupported")
	}
	if len(data) < 16 {
		return fmt.Errorf("fmt chunk is shorter than 16 bytes")
	}
	f.encoding = int(binary.LittleEndian.Uint16(data[0:2]))
	f.channels = int(binary.LittleEndian.Uint16(data[2:4]))
	f.sampleRate = int(binary.LittleEndian.Uint32(data[4:8]))
	byteRate := int(binary.LittleEndian.Uint32(data[8:12]))
	f.blockAlign = int(binary.LittleEndian.Uint16(data[12:14]))
	f.bits = int(binary.LittleEndian.Uint16(data[14:16]))
	if f.encoding != 1 && f.encoding != 3 {
		return fmt.Errorf("audio encoding %d is unsupported", f.encoding)
	}
	if f.channels <= 0 || f.sampleRate <= 0 {
		return fmt.Errorf("channel count and sample rate must be positive")
	}
	if f.encoding == 1 && f.bits != 8 && f.bits != 16 && f.bits != 24 && f.bits != 32 {
		return fmt.Errorf("PCM bit depth %d is unsupported", f.bits)
	}
	if f.encoding == 3 && f.bits != 32 {
		return fmt.Errorf("IEEE float bit depth %d is unsupported", f.bits)
	}
	f.bytesPerSample = f.bits / 8
	if f.blockAlign != f.channels*f.bytesPerSample || byteRate != f.sampleRate*f.blockAlign {
		return fmt.Errorf("fmt chunk has inconsistent frame alignment or byte rate")
	}
	f.present = true
	return nil
}

func (f wavFormat) sample(data []byte) (float32, error) {
	if f.encoding == 3 {
		value := math.Float32frombits(binary.LittleEndian.Uint32(data))
		if math.IsNaN(float64(value)) || math.IsInf(float64(value), 0) {
			return 0, fmt.Errorf("float sample is not finite")
		}
		return value, nil
	}
	switch f.bits {
	case 8:
		return (float32(data[0]) - 128) / 128, nil
	case 16:
		return float32(int16(binary.LittleEndian.Uint16(data))) / 32768, nil
	case 24:
		value := int32(data[0]) | int32(data[1])<<8 | int32(data[2])<<16
		if value&0x800000 != 0 {
			value |= ^int32(0xffffff)
		}
		return float32(value) / 8388608, nil
	case 32:
		return float32(int32(binary.LittleEndian.Uint32(data))) / 2147483648, nil
	default:
		return 0, fmt.Errorf("PCM bit depth %d is unsupported", f.bits)
	}
}

func readAsset(path string, source io.Reader) ([]byte, error) {
	if source == nil {
		return nil, fmt.Errorf("decode asset %q: source must not be nil", path)
	}
	data, err := io.ReadAll(io.LimitReader(source, maxDecodedAssetBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read asset %q: %w", path, err)
	}
	if len(data) > maxDecodedAssetBytes {
		return nil, fmt.Errorf("read asset %q: exceeds %d-byte decoded asset limit", path, maxDecodedAssetBytes)
	}
	return data, nil
}

func validLoadPath(path string) bool {
	return fs.ValidPath(path)
}
