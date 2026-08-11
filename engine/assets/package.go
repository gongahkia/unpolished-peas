package assets

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"sort"
	"strings"
)

// PackageVersion is the current serialized project-asset package format.
const PackageVersion = 1

// AssetType identifies a standard asset decoder used during package validation.
type AssetType string

const (
	AssetImage   AssetType = "image"
	AssetFont    AssetType = "font"
	AssetAudio   AssetType = "audio"
	AssetTileMap AssetType = "tile-map"
)

// AssetMode controls whether package bytes contain an asset's source data.
type AssetMode string

const (
	EmbedAsset    AssetMode = "embed"
	ExternalAsset AssetMode = "external"
)

// ProjectManifest describes project-relative source assets and their package
// relationships. All fields are required except Dependencies, which is empty
// when an asset has no source-level dependencies.
type ProjectManifest struct {
	Version int             `json:"version"`
	Name    string          `json:"name"`
	Assets  []ManifestAsset `json:"assets"`
}

// ManifestAsset is one declared source asset.
type ManifestAsset struct {
	Path         string    `json:"path"`
	Type         AssetType `json:"type"`
	Mode         AssetMode `json:"mode"`
	Dependencies []string  `json:"dependencies,omitempty"`
}

// Package is a deterministic serialized build artifact. Embedded records carry
// source bytes; external records carry only a validated SHA-256 digest.
type Package struct {
	Version int            `json:"version"`
	Name    string         `json:"name"`
	Assets  []PackageAsset `json:"assets"`
}

// PackageAsset is a validated package record.
type PackageAsset struct {
	Path         string    `json:"path"`
	Type         AssetType `json:"type"`
	Mode         AssetMode `json:"mode"`
	SHA256       string    `json:"sha256"`
	Dependencies []string  `json:"dependencies,omitempty"`
	Data         []byte    `json:"data,omitempty"`
}

// LoadProjectManifest reads and validates a versioned project manifest from a
// project filesystem. path must itself be project-relative.
func LoadProjectManifest(source fs.FS, path string) (ProjectManifest, error) {
	if source == nil {
		return ProjectManifest{}, fmt.Errorf("asset manifest filesystem must not be nil")
	}
	if !fs.ValidPath(path) {
		return ProjectManifest{}, fmt.Errorf("asset manifest path %q must be project-relative", path)
	}
	file, err := source.Open(path)
	if err != nil {
		return ProjectManifest{}, fmt.Errorf("open asset manifest %q: %w", path, err)
	}
	defer file.Close()
	data, err := readAsset(path, file)
	if err != nil {
		return ProjectManifest{}, err
	}
	var manifest ProjectManifest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return ProjectManifest{}, fmt.Errorf("decode asset manifest %q: %w", path, err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ProjectManifest{}, fmt.Errorf("decode asset manifest %q: expected one JSON value", path)
	}
	if err := manifest.validate(); err != nil {
		return ProjectManifest{}, fmt.Errorf("validate asset manifest %q: %w", path, err)
	}
	return manifest, nil
}

// BuildPackage validates every declared source asset and returns canonical JSON
// bytes. Equal filesystem content and manifest values produce equal artifacts
// regardless of manifest asset or dependency ordering.
func BuildPackage(source fs.FS, manifest ProjectManifest) ([]byte, error) {
	if source == nil {
		return nil, fmt.Errorf("asset package filesystem must not be nil")
	}
	if err := manifest.validate(); err != nil {
		return nil, fmt.Errorf("validate asset manifest: %w", err)
	}
	assets := append([]ManifestAsset(nil), manifest.Assets...)
	sort.Slice(assets, func(left, right int) bool { return assets[left].Path < assets[right].Path })
	types := make(map[string]AssetType, len(assets))
	for _, asset := range assets {
		types[asset.Path] = asset.Type
	}
	packageAssets := make([]PackageAsset, 0, len(assets))
	decodedTileMaps := make(map[string]TileMap)
	for _, asset := range assets {
		data, err := packageSource(source, asset.Path)
		if err != nil {
			return nil, err
		}
		if err := validatePackageAsset(asset, data, decodedTileMaps); err != nil {
			return nil, err
		}
		digest := sha256.Sum256(data)
		record := PackageAsset{
			Path:         asset.Path,
			Type:         asset.Type,
			Mode:         asset.Mode,
			SHA256:       hex.EncodeToString(digest[:]),
			Dependencies: sortedStrings(asset.Dependencies),
		}
		if asset.Mode == EmbedAsset {
			record.Data = append([]byte(nil), data...)
		}
		packageAssets = append(packageAssets, record)
	}
	for _, asset := range assets {
		tiles, ok := decodedTileMaps[asset.Path]
		if !ok {
			continue
		}
		if !contains(asset.Dependencies, tiles.Texture) {
			return nil, fmt.Errorf("package tile map %q must declare texture %q as a dependency", asset.Path, tiles.Texture)
		}
		if types[tiles.Texture] != AssetImage {
			return nil, fmt.Errorf("package tile map %q texture dependency %q must be an image asset", asset.Path, tiles.Texture)
		}
	}
	artifact, err := json.Marshal(Package{Version: manifest.Version, Name: manifest.Name, Assets: packageAssets})
	if err != nil {
		return nil, fmt.Errorf("encode asset package: %w", err)
	}
	return artifact, nil
}

func (m ProjectManifest) validate() error {
	if m.Version != PackageVersion {
		return fmt.Errorf("version %d is unsupported, want %d", m.Version, PackageVersion)
	}
	if strings.TrimSpace(m.Name) == "" {
		return fmt.Errorf("name must not be empty")
	}
	if len(m.Assets) == 0 {
		return fmt.Errorf("assets must not be empty")
	}
	paths := make(map[string]ManifestAsset, len(m.Assets))
	for _, asset := range m.Assets {
		if !fs.ValidPath(asset.Path) {
			return fmt.Errorf("asset path %q must be project-relative", asset.Path)
		}
		if !asset.Type.valid() {
			return fmt.Errorf("asset %q has unsupported type %q", asset.Path, asset.Type)
		}
		if asset.Mode != EmbedAsset && asset.Mode != ExternalAsset {
			return fmt.Errorf("asset %q has unsupported mode %q", asset.Path, asset.Mode)
		}
		if _, exists := paths[asset.Path]; exists {
			return fmt.Errorf("asset path %q is declared more than once", asset.Path)
		}
		paths[asset.Path] = asset
	}
	for _, asset := range m.Assets {
		seen := make(map[string]bool, len(asset.Dependencies))
		for _, dependency := range asset.Dependencies {
			if !fs.ValidPath(dependency) {
				return fmt.Errorf("asset %q dependency %q must be project-relative", asset.Path, dependency)
			}
			if seen[dependency] {
				return fmt.Errorf("asset %q declares dependency %q more than once", asset.Path, dependency)
			}
			if dependency == asset.Path {
				return fmt.Errorf("asset %q cannot depend on itself", asset.Path)
			}
			if _, exists := paths[dependency]; !exists {
				return fmt.Errorf("asset %q depends on undeclared asset %q", asset.Path, dependency)
			}
			seen[dependency] = true
		}
	}
	return nil
}

func (t AssetType) valid() bool {
	return t == AssetImage || t == AssetFont || t == AssetAudio || t == AssetTileMap
}

func packageSource(source fs.FS, path string) ([]byte, error) {
	file, err := source.Open(path)
	if err != nil {
		return nil, fmt.Errorf("package asset %q: open source: %w", path, err)
	}
	defer file.Close()
	data, err := readAsset(path, file)
	if err != nil {
		return nil, fmt.Errorf("package asset %q: %w", path, err)
	}
	return data, nil
}

func validatePackageAsset(asset ManifestAsset, data []byte, decodedTileMaps map[string]TileMap) error {
	reader := bytes.NewReader(data)
	switch asset.Type {
	case AssetImage:
		if _, err := DecodeImage(asset.Path, reader); err != nil {
			return fmt.Errorf("package asset %q: %w", asset.Path, err)
		}
	case AssetFont:
		if _, err := DecodeFont(asset.Path, reader); err != nil {
			return fmt.Errorf("package asset %q: %w", asset.Path, err)
		}
	case AssetAudio:
		if _, err := DecodeWAV(asset.Path, reader); err != nil {
			return fmt.Errorf("package asset %q: %w", asset.Path, err)
		}
	case AssetTileMap:
		tiles, err := DecodeTileMap(asset.Path, reader)
		if err != nil {
			return fmt.Errorf("package asset %q: %w", asset.Path, err)
		}
		decodedTileMaps[asset.Path] = tiles
	default:
		return fmt.Errorf("package asset %q: unsupported type %q", asset.Path, asset.Type)
	}
	return nil
}

func sortedStrings(values []string) []string {
	copy := append([]string(nil), values...)
	sort.Strings(copy)
	return copy
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
