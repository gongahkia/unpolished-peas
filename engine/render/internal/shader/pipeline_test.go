package shader

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/gongahkia/72/engine/diagnostics"
)

func TestEmbeddedSpriteAssetIsVersionedAndPremultipliesOutput(t *testing.T) {
	assets := Assets()
	if len(assets) != 2 || assets[0].Name != Sprite2DAsset || assets[1].Name != Sprite2DInstancedAsset || assets[0].Version != sprite2DVer || assets[1].Version != sprite2DVer {
		t.Fatalf("embedded assets = %+v", assets)
	}
	for _, required := range []string{"@vertex", "vs_instanced", "@fragment", "textureSample", "sample.rgb * input.tint.rgb * alpha"} {
		if !strings.Contains(assets[0].Source, required) {
			t.Fatalf("sprite WGSL does not contain %q", required)
		}
	}
}

func TestCacheReusesEquivalentPipelineKey(t *testing.T) {
	compiler := &fakeCompiler{}
	cache := NewCache(compiler)
	left := testRequest()
	right := testRequest()
	first, reused, err := cache.Pipeline(left)
	if err != nil || reused {
		t.Fatalf("first pipeline = %v, reused=%t, err=%v", first, reused, err)
	}
	second, reused, err := cache.Pipeline(right)
	if err != nil || !reused || first != second || cache.Count() != 1 {
		t.Fatalf("equivalent pipeline = %v, reused=%t, err=%v, count=%d", second, reused, err, cache.Count())
	}
	if len(compiler.validated) != 1 || len(compiler.created) != 1 {
		t.Fatalf("compiler calls validation=%d creation=%d", len(compiler.validated), len(compiler.created))
	}
	if got, want := compiler.created[0].Blend, BlendSourceOver.State(); got != want || compiler.created[0].Alpha != AlphaStraight {
		t.Fatalf("descriptor policy = %+v, want blend=%+v alpha=%d", compiler.created[0], want, AlphaStraight)
	}

	additive := testRequest()
	additive.Blend = BlendAdditive
	if _, reused, err := cache.Pipeline(additive); err != nil || reused || cache.Count() != 2 {
		t.Fatalf("additive pipeline reused=%t err=%v count=%d", reused, err, cache.Count())
	}
	if len(compiler.validated) != 1 || len(compiler.created) != 2 {
		t.Fatalf("compiler calls after new key validation=%d creation=%d", len(compiler.validated), len(compiler.created))
	}

	differentTarget := testRequest()
	differentTarget.TargetFormat = "bgra8unorm"
	if _, reused, err := cache.Pipeline(differentTarget); err != nil || reused || cache.Count() != 3 {
		t.Fatalf("different target pipeline reused=%t err=%v count=%d", reused, err, cache.Count())
	}
	if len(compiler.validated) != 1 || len(compiler.created) != 3 {
		t.Fatalf("compiler calls after target key validation=%d creation=%d", len(compiler.validated), len(compiler.created))
	}
}

func TestCacheReturnsContextualValidationFailure(t *testing.T) {
	cause := errors.New("line 17: invalid WGSL token")
	compiler := &fakeCompiler{validateErr: cause}
	_, _, err := NewCache(compiler).Pipeline(testRequest())
	assertShaderFailure(t, err, "validate shader sprite-2d@v1", diagnostics.CorrectConfiguration, true, cause)
}

func TestCacheRejectsInvalidPipelineKeyBeforeCompilerCalls(t *testing.T) {
	emptyFormat := testRequest()
	emptyFormat.TargetFormat = ""
	zeroSamples := testRequest()
	zeroSamples.TargetSampleCount = 0
	tests := []struct {
		name    string
		request Request
	}{
		{name: "empty target format", request: emptyFormat},
		{name: "zero target sample count", request: zeroSamples},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			compiler := &fakeCompiler{}
			_, _, err := NewCache(compiler).Pipeline(test.request)
			if err == nil {
				t.Fatal("invalid key produced a pipeline")
			}
			if len(compiler.validated) != 0 || len(compiler.created) != 0 {
				t.Fatalf("compiler called before key validation: validation=%d creation=%d", len(compiler.validated), len(compiler.created))
			}
		})
	}
}

func TestBlendStatesMatchDocumentedPremultipliedPolicy(t *testing.T) {
	tests := []struct {
		mode BlendMode
		want BlendState
	}{
		{BlendSourceOver, BlendState{Color: BlendComponent{BlendFactorOne, BlendFactorOneMinusSourceAlpha, BlendOperationAdd}, Alpha: BlendComponent{BlendFactorOne, BlendFactorOneMinusSourceAlpha, BlendOperationAdd}}},
		{BlendReplace, BlendState{Color: BlendComponent{BlendFactorOne, BlendFactorZero, BlendOperationAdd}, Alpha: BlendComponent{BlendFactorOne, BlendFactorZero, BlendOperationAdd}}},
		{BlendAdditive, BlendState{Color: BlendComponent{BlendFactorOne, BlendFactorOne, BlendOperationAdd}, Alpha: BlendComponent{BlendFactorOne, BlendFactorOne, BlendOperationAdd}}},
	}
	for _, test := range tests {
		if got := test.mode.State(); !reflect.DeepEqual(got, test.want) {
			t.Fatalf("blend state for %d = %+v, want %+v", test.mode, got, test.want)
		}
	}
}

func assertShaderFailure(t *testing.T, err error, operation string, recovery diagnostics.Recovery, terminal bool, cause error) {
	t.Helper()
	var failure *diagnostics.Failure
	if !errors.As(err, &failure) {
		t.Fatalf("error %v is not a structured renderer failure", err)
	}
	if failure.Subsystem != diagnostics.RendererSubsystem || failure.Operation != operation || failure.Recovery != recovery || failure.Terminal != terminal {
		t.Fatalf("failure = %+v", failure)
	}
	if !errors.Is(err, cause) {
		t.Fatalf("failure %v does not retain cause %v", err, cause)
	}
}

type fakeCompiler struct {
	validated   []Asset
	created     []Descriptor
	validateErr error
}

func (c *fakeCompiler) ValidateWGSL(asset Asset) error {
	c.validated = append(c.validated, asset)
	return c.validateErr
}

func (c *fakeCompiler) CreatePipeline(descriptor Descriptor) (any, error) {
	c.created = append(c.created, descriptor)
	return &fakePipeline{len(c.created)}, nil
}

type fakePipeline struct{ identifier int }

func testRequest() Request {
	return Request{Asset: Sprite2DAsset, Blend: BlendSourceOver, Sampling: SamplingNearest, TargetFormat: "rgba8unorm", TargetSampleCount: 1}
}
