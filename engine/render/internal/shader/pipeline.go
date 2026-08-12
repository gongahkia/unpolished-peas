// Package shader owns versioned engine WGSL assets and private pipeline-cache
// identity. A selected graphics binding implements Compiler; its types do not
// escape this package.
package shader

import (
	_ "embed"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/gongahkia/72/engine/diagnostics"
	"github.com/gongahkia/72/engine/render"
)

const (
	// Sprite2DAsset renders expanded triangle-list geometry. Sprite2DInstancedAsset
	// uses the same versioned WGSL with a per-sprite instance layout. Their names
	// remain distinct pipeline-cache identities.
	Sprite2DAsset          = "sprite-2d"
	Sprite2DInstancedAsset = "sprite-2d-instanced"
	sprite2DVer            = "v1"
)

//go:embed assets/sprite-2d-v1.wgsl
var sprite2DWGSL string

// Asset is an immutable, engine-provided WGSL source. Assets are private to
// the renderer: applications cannot register or execute arbitrary shaders.
type Asset struct {
	Name    string
	Version string
	Source  string
}

var embeddedAssets = []Asset{
	{Name: Sprite2DAsset, Version: sprite2DVer, Source: sprite2DWGSL},
	{Name: Sprite2DInstancedAsset, Version: sprite2DVer, Source: sprite2DWGSL},
}

// Assets returns copies of all versioned embedded WGSL assets.
func Assets() []Asset { return append([]Asset(nil), embeddedAssets...) }

func assetByName(name string) (Asset, bool) {
	for _, asset := range embeddedAssets {
		if asset.Name == name {
			return asset, true
		}
	}
	return Asset{}, false
}

// BlendMode is a private pipeline blend selection. Source-over is the default
// engine behavior; replace and additive remain explicit pipeline choices for
// future engine-owned materials.
type BlendMode uint8

const (
	BlendSourceOver BlendMode = iota
	BlendReplace
	BlendAdditive
)

func (m BlendMode) valid() bool {
	return m == BlendSourceOver || m == BlendReplace || m == BlendAdditive
}

// BlendFactor and BlendOperation describe binding-neutral blend state. A
// chosen adapter maps these values to its private graphics API types.
type BlendFactor uint8

const (
	BlendFactorZero BlendFactor = iota
	BlendFactorOne
	BlendFactorOneMinusSourceAlpha
)

type BlendOperation uint8

const BlendOperationAdd BlendOperation = iota

// BlendComponent controls one color or alpha blend calculation.
type BlendComponent struct {
	Source, Destination BlendFactor
	Operation           BlendOperation
}

// BlendState contains distinct color and alpha blend components.
type BlendState struct {
	Color, Alpha BlendComponent
}

// State returns the premultiplied-output blend state for mode. Replace is
// suitable only when the application knows every fragment is opaque.
func (m BlendMode) State() BlendState {
	switch m {
	case BlendReplace:
		return BlendState{
			Color: BlendComponent{Source: BlendFactorOne, Destination: BlendFactorZero, Operation: BlendOperationAdd},
			Alpha: BlendComponent{Source: BlendFactorOne, Destination: BlendFactorZero, Operation: BlendOperationAdd},
		}
	case BlendAdditive:
		return BlendState{
			Color: BlendComponent{Source: BlendFactorOne, Destination: BlendFactorOne, Operation: BlendOperationAdd},
			Alpha: BlendComponent{Source: BlendFactorOne, Destination: BlendFactorOne, Operation: BlendOperationAdd},
		}
	default:
		return BlendState{
			Color: BlendComponent{Source: BlendFactorOne, Destination: BlendFactorOneMinusSourceAlpha, Operation: BlendOperationAdd},
			Alpha: BlendComponent{Source: BlendFactorOne, Destination: BlendFactorOneMinusSourceAlpha, Operation: BlendOperationAdd},
		}
	}
}

// Sampling selects the sampler interpolation policy. Mipmap generation and
// anisotropic filtering are intentionally outside this initial foundation.
type Sampling uint8

const (
	SamplingNearest Sampling = iota
	SamplingLinear
)

func (s Sampling) valid() bool { return s == SamplingNearest || s == SamplingLinear }

// AlphaMode records the portable input convention. All current render.Color
// and render.Image values are straight alpha; the embedded sprite shader
// converts them to premultiplied output before blending.
type AlphaMode uint8

const AlphaStraight AlphaMode = iota

// Request identifies one desired engine-owned pipeline. Material is the
// existing public command value; cache identity canonicalizes its parameter map
// without retaining it or exposing a native pipeline type.
type Request struct {
	Asset             string
	Material          render.Material
	Blend             BlendMode
	Sampling          Sampling
	TargetFormat      string
	TargetSampleCount uint32
}

// Key is a comparable, canonical pipeline cache key. Parameters stores a
// length-prefixed, sorted binary-float representation rather than a map so
// semantically equivalent Material maps reuse one pipeline.
type Key struct {
	Asset, Version, Material, Parameters string
	Blend, Sampling                      uint8
	Alpha                                AlphaMode
	TargetFormat                         string
	TargetSampleCount                    uint32
}

// Descriptor is passed to a selected binding after validation. It contains no
// binding type and gives adapters the source, deterministic key, and policy
// needed to create a native render pipeline.
type Descriptor struct {
	Asset             Asset
	Key               Key
	Blend             BlendState
	Sampling          Sampling
	Alpha             AlphaMode
	TargetFormat      string
	TargetSampleCount uint32
}

// Compiler is implemented by a selected private graphics adapter. Validation
// must call the binding's WGSL compiler/validator and retain its diagnostic in
// the returned error. CreatePipeline may return any private native handle.
type Compiler interface {
	ValidateWGSL(Asset) error
	CreatePipeline(Descriptor) (any, error)
}

// Cache validates every asset once per device-local cache and creates one
// native pipeline per canonical Key. It is render-thread confined, like native
// device and resource ownership.
type Cache struct {
	compiler  Compiler
	validated map[string]struct{}
	pipelines map[Key]any
}

// NewCache creates an empty private pipeline cache for compiler.
func NewCache(compiler Compiler) *Cache {
	return &Cache{compiler: compiler, validated: make(map[string]struct{}), pipelines: make(map[Key]any)}
}

// Pipeline returns a native pipeline and whether it was reused from this
// device-local cache. Failures include the operation and embedded asset in a
// structured renderer diagnostic.
func (c *Cache) Pipeline(request Request) (pipeline any, reused bool, err error) {
	if c == nil || c.compiler == nil {
		return nil, false, diagnostics.NewFailure(diagnostics.RendererSubsystem, "create shader pipeline", fmt.Errorf("shader compiler must not be nil"), diagnostics.CorrectConfiguration, true)
	}
	asset, ok := assetByName(request.Asset)
	if !ok {
		return nil, false, diagnostics.NewFailure(diagnostics.RendererSubsystem, "load shader asset", fmt.Errorf("embedded shader %q is unavailable", request.Asset), diagnostics.CorrectConfiguration, true)
	}
	key, err := request.key(asset)
	if err != nil {
		return nil, false, err
	}
	if pipeline, ok := c.pipelines[key]; ok {
		return pipeline, true, nil
	}
	identity := asset.Name + "@" + asset.Version
	if _, ok := c.validated[identity]; !ok {
		if err := c.compiler.ValidateWGSL(asset); err != nil {
			return nil, false, diagnostics.NewFailure(diagnostics.RendererSubsystem, "validate shader "+identity, err, diagnostics.CorrectConfiguration, true)
		}
		c.validated[identity] = struct{}{}
	}
	descriptor := Descriptor{Asset: asset, Key: key, Blend: request.Blend.State(), Sampling: request.Sampling, Alpha: AlphaStraight, TargetFormat: request.TargetFormat, TargetSampleCount: request.TargetSampleCount}
	pipeline, err = c.compiler.CreatePipeline(descriptor)
	if err != nil {
		return nil, false, diagnostics.NewFailure(diagnostics.RendererSubsystem, "create pipeline for shader "+identity, err, diagnostics.CorrectConfiguration, true)
	}
	c.pipelines[key] = pipeline
	return pipeline, false, nil
}

// Count reports cached native pipelines. It is intended for a future backend's
// internal resource metrics, not a driver-memory estimate.
func (c *Cache) Count() int {
	if c == nil {
		return 0
	}
	return len(c.pipelines)
}

func (r Request) key(asset Asset) (Key, error) {
	if !r.Blend.valid() {
		return Key{}, diagnostics.NewFailure(diagnostics.RendererSubsystem, "create shader pipeline key", fmt.Errorf("unsupported blend mode %d", r.Blend), diagnostics.CorrectInput, false)
	}
	if !r.Sampling.valid() {
		return Key{}, diagnostics.NewFailure(diagnostics.RendererSubsystem, "create shader pipeline key", fmt.Errorf("unsupported sampling mode %d", r.Sampling), diagnostics.CorrectInput, false)
	}
	if r.TargetFormat == "" {
		return Key{}, diagnostics.NewFailure(diagnostics.RendererSubsystem, "create shader pipeline key", fmt.Errorf("pipeline target format must not be empty"), diagnostics.CorrectInput, false)
	}
	if r.TargetSampleCount == 0 {
		return Key{}, diagnostics.NewFailure(diagnostics.RendererSubsystem, "create shader pipeline key", fmt.Errorf("pipeline target sample count must be positive"), diagnostics.CorrectInput, false)
	}
	parameters, err := canonicalParameters(r.Material.Parameters)
	if err != nil {
		return Key{}, diagnostics.NewFailure(diagnostics.RendererSubsystem, "create shader pipeline key", err, diagnostics.CorrectInput, false)
	}
	return Key{Asset: asset.Name, Version: asset.Version, Material: r.Material.Name, Parameters: parameters, Blend: uint8(r.Blend), Sampling: uint8(r.Sampling), Alpha: AlphaStraight, TargetFormat: r.TargetFormat, TargetSampleCount: r.TargetSampleCount}, nil
}

func canonicalParameters(parameters map[string]float64) (string, error) {
	keys := make([]string, 0, len(parameters))
	for key := range parameters {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var encoded strings.Builder
	for _, key := range keys {
		value := parameters[key]
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return "", fmt.Errorf("material parameter %q must be finite", key)
		}
		if value == 0 {
			value = 0 // Canonicalize negative zero, which is numerically equivalent.
		}
		fmt.Fprintf(&encoded, "%d:%s=%016x;", len(key), key, math.Float64bits(value))
	}
	return encoded.String(), nil
}
