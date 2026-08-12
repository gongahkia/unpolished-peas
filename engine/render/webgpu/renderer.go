// Package webgpu contains 72's engine-owned WebGPU command renderer.
//
// It is an implementation package: applications submit render.Frame through
// engine hosts and never receive its binding types.
package webgpu

import (
	"fmt"
	"image"
	"image/color"
	"math"
	"sort"
	"time"

	"github.com/gogpu/gputypes"
	"github.com/gogpu/wgpu"
	"github.com/gongahkia/72/engine/diagnostics"
	"github.com/gongahkia/72/engine/render"
	"github.com/gongahkia/72/engine/render/internal/shader"
	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	vertexStride    = 32
	defaultFontSize = 13
)

// Renderer translates complete engine command frames into binding-private
// WebGPU resources and submissions. All methods are confined to the host
// owner goroutine.
type Renderer struct {
	instance *wgpu.Instance
	surface  *wgpu.Surface
	adapter  *wgpu.Adapter
	device   *wgpu.Device
	format   wgpu.TextureFormat

	width, height               int
	logicalWidth, logicalHeight int

	bindGroupLayout *wgpu.BindGroupLayout
	pipelineLayout  *wgpu.PipelineLayout
	pipelines       *shader.Cache
	nativePipelines []*wgpu.RenderPipeline

	textures     map[uint64]*textureResource
	atlasPages   map[atlasPageKey]*textureResource
	basicGlyphs  map[rune]*textureResource
	whiteTexture *textureResource

	textureUploads uint64
	closed         bool
}

type textureResource struct {
	texture  *wgpu.Texture
	view     *wgpu.TextureView
	bind     *wgpu.BindGroup
	width    int
	height   int
	revision uint64
}

type atlasPageKey struct {
	atlas *render.GlyphAtlas
	page  int
}

type vertex struct {
	x, y, u, v float32
	r, g, b, a float32
}

type batch struct {
	texture  *textureResource
	clip     *render.Rect
	vertices []vertex
}

// newRenderer adopts a binding-private surface created by a platform-specific
// constructor. width and height are physical presentation pixels.
func newRenderer(instance *wgpu.Instance, surface *wgpu.Surface, width, height int) (*Renderer, error) {
	return newRendererWithFormat(instance, surface, width, height, wgpu.TextureFormatBGRA8Unorm)
}

func newRendererWithFormat(instance *wgpu.Instance, surface *wgpu.Surface, width, height int, format wgpu.TextureFormat) (*Renderer, error) {
	if instance == nil || surface == nil {
		return nil, fmt.Errorf("initialize WebGPU renderer: instance and surface must not be nil")
	}
	if width <= 0 || height <= 0 {
		return nil, fmt.Errorf("initialize WebGPU renderer: surface size must be positive, got %dx%d", width, height)
	}
	adapter, err := instance.RequestAdapter(&wgpu.RequestAdapterOptions{CompatibleSurface: surface})
	if err != nil {
		return nil, fmt.Errorf("select WebGPU adapter: %w", err)
	}
	device, err := adapter.RequestDevice(nil)
	if err != nil {
		adapter.Release()
		return nil, fmt.Errorf("create WebGPU device: %w", err)
	}
	r := &Renderer{
		instance:      instance,
		surface:       surface,
		adapter:       adapter,
		device:        device,
		format:        format,
		width:         width,
		height:        height,
		logicalWidth:  width,
		logicalHeight: height,
		textures:      make(map[uint64]*textureResource),
		atlasPages:    make(map[atlasPageKey]*textureResource),
		basicGlyphs:   make(map[rune]*textureResource),
	}
	if err := r.initialize(); err != nil {
		r.Close()
		return nil, err
	}
	if err := r.Resize(width, height); err != nil {
		r.Close()
		return nil, err
	}
	return r, nil
}

// SetLogicalSize sets the engine-coordinate extent mapped to the current
// physical surface. Hosts use Resize for physical DPI and window changes.
func (r *Renderer) SetLogicalSize(width, height int) error {
	if r == nil || r.closed {
		return fmt.Errorf("set WebGPU logical size: renderer is closed")
	}
	if width <= 0 || height <= 0 {
		return fmt.Errorf("set WebGPU logical size: dimensions must be positive, got %dx%d", width, height)
	}
	r.logicalWidth, r.logicalHeight = width, height
	return nil
}

func (r *Renderer) initialize() error {
	layout, err := r.device.CreateBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
		Label: "72 sprite texture layout",
		Entries: []gputypes.BindGroupLayoutEntry{
			{Binding: 0, Visibility: gputypes.ShaderStageFragment, Texture: &gputypes.TextureBindingLayout{SampleType: gputypes.TextureSampleTypeFloat, ViewDimension: gputypes.TextureViewDimension2D}},
			{Binding: 1, Visibility: gputypes.ShaderStageFragment, Sampler: &gputypes.SamplerBindingLayout{Type: gputypes.SamplerBindingTypeFiltering}},
		},
	})
	if err != nil {
		return fmt.Errorf("create sprite texture layout: %w", err)
	}
	r.bindGroupLayout = layout
	pipelineLayout, err := r.device.CreatePipelineLayout(&wgpu.PipelineLayoutDescriptor{Label: "72 sprite pipeline layout", BindGroupLayouts: []*wgpu.BindGroupLayout{layout}})
	if err != nil {
		return fmt.Errorf("create sprite pipeline layout: %w", err)
	}
	r.pipelineLayout = pipelineLayout
	r.pipelines = shader.NewCache(shaderCompiler{renderer: r})
	white, err := r.createTexture(render.Image{Width: 1, Height: 1, Pixels: []byte{255, 255, 255, 255}}, 1, "72 white texture")
	if err != nil {
		return fmt.Errorf("create private white texture: %w", err)
	}
	r.whiteTexture = white
	return nil
}

// Resize configures the private presentation surface. Zero dimensions suspend
// presentation until a later non-zero resize.
func (r *Renderer) Resize(width, height int) error {
	if r == nil || r.closed {
		return fmt.Errorf("resize WebGPU surface: renderer is closed")
	}
	if width < 0 || height < 0 {
		return fmt.Errorf("resize WebGPU surface: dimensions must not be negative")
	}
	r.width, r.height = width, height
	if width == 0 || height == 0 {
		r.surface.Unconfigure()
		return nil
	}
	if err := r.surface.Configure(r.device, &wgpu.SurfaceConfiguration{
		Format: r.format, Usage: wgpu.TextureUsageRenderAttachment,
		Width: uint32(width), Height: uint32(height), PresentMode: wgpu.PresentModeFifo,
		AlphaMode: gputypes.CompositeAlphaModeOpaque,
	}); err != nil {
		return fmt.Errorf("configure WebGPU surface %dx%d: %w", width, height, err)
	}
	return nil
}

// Render submits frame to the configured presentation surface.
func (r *Renderer) Render(frame render.Frame) (err error) {
	if err := r.available("render WebGPU frame"); err != nil {
		return err
	}
	if r.width == 0 || r.height == 0 {
		return nil
	}
	texture, _, err := r.surface.GetCurrentTexture()
	if err != nil {
		return rendererFailure("acquire WebGPU surface frame", err, diagnostics.Retry, false)
	}
	defer func() {
		if err != nil {
			r.surface.DiscardTexture()
		}
	}()
	view, err := texture.CreateView(nil)
	if err != nil {
		r.surface.DiscardTexture()
		return rendererFailure("create WebGPU surface view", err, diagnostics.Retry, false)
	}
	defer view.Release()
	if err := r.renderToView(frame, view, r.width, r.height, r.logicalWidth, r.logicalHeight); err != nil {
		return err
	}
	if err := r.surface.Present(texture); err != nil {
		return rendererFailure("present WebGPU surface frame", err, diagnostics.Retry, false)
	}
	return nil
}

// RenderTo submits a frame to a TextureStore-owned target. Its GPU texture is
// immediately available to later sprite commands on this renderer. Portable
// target pixels remain the recovery seed after device recreation.
func (r *Renderer) RenderTo(frame render.Frame, target render.RenderTarget) error {
	if err := r.available("render WebGPU target"); err != nil {
		return err
	}
	if frame.Textures == nil {
		return rendererFailure("render WebGPU target", fmt.Errorf("render target requires an engine texture store"), diagnostics.CorrectInput, false)
	}
	resource, err := r.renderTarget(frame.Textures, target)
	if err != nil {
		return rendererFailure("render WebGPU target", err, diagnostics.CorrectInput, false)
	}
	return r.renderToView(frame, resource.view, resource.width, resource.height, resource.width, resource.height)
}

func (r *Renderer) renderToView(frame render.Frame, target *wgpu.TextureView, width, height, logicalWidth, logicalHeight int) (err error) {
	if frame.Queue == nil {
		return rendererFailure("render WebGPU frame", fmt.Errorf("render frame queue must not be nil"), diagnostics.CorrectInput, false)
	}
	if target == nil || width <= 0 || height <= 0 {
		return rendererFailure("render WebGPU frame", fmt.Errorf("render target must be initialized"), diagnostics.CorrectConfiguration, true)
	}
	started := time.Now()
	metrics := render.CollectFrameMetrics(frame, render.Rect{W: float64(logicalWidth), H: float64(logicalHeight)})
	uploads := r.textureUploads
	defer func() {
		metrics.Duration = time.Since(started)
		metrics.TextureUploads = r.textureUploads - uploads
		metrics.NativeTextureEntries, metrics.NativeTextureBytes = r.cacheStats()
		metrics.RecordInto(frame.Diagnostics)
	}()
	r.pruneResources(frame.Textures)
	commands := orderedCommands(frame.Queue.Commands())
	clear := gputypes.Color{}
	hasClear := false
	for _, command := range commands {
		if command.Kind != render.Clear {
			continue
		}
		value, ok := command.Payload.(render.Color)
		if !ok {
			return rendererFailure("render WebGPU clear", fmt.Errorf("clear command has payload %T", command.Payload), diagnostics.CorrectInput, false)
		}
		clear, hasClear = colorValue(value), true
	}
	encoder, err := r.device.CreateCommandEncoder(&wgpu.CommandEncoderDescriptor{Label: "72 render frame"})
	if err != nil {
		return rendererFailure("create WebGPU command encoder", err, diagnostics.Restart, true)
	}
	load := gputypes.LoadOpLoad
	if hasClear {
		load = gputypes.LoadOpClear
	}
	pass, err := encoder.BeginRenderPass(&wgpu.RenderPassDescriptor{Label: "72 2D pass", ColorAttachments: []wgpu.RenderPassColorAttachment{{View: target, LoadOp: load, StoreOp: gputypes.StoreOpStore, ClearValue: clear}}})
	if err != nil {
		return rendererFailure("begin WebGPU render pass", err, diagnostics.Restart, true)
	}
	batches, err := r.batches(frame, commands, logicalWidth, logicalHeight)
	if err != nil {
		_ = pass.End()
		return err
	}
	buffers := make([]*wgpu.Buffer, 0, len(batches))
	defer func() {
		for _, buffer := range buffers {
			buffer.Release()
		}
	}()
	for _, batch := range batches {
		buffer, err := r.submitBatch(pass, batch, width, height, logicalWidth, logicalHeight)
		if err != nil {
			_ = pass.End()
			return err
		}
		if buffer != nil {
			buffers = append(buffers, buffer)
		}
	}
	metrics.Batches = uint64(len(buffers))
	metrics.DrawCalls = uint64(len(buffers))
	if err := pass.End(); err != nil {
		return rendererFailure("end WebGPU render pass", err, diagnostics.Restart, true)
	}
	commandsBuffer, err := encoder.Finish()
	if err != nil {
		return rendererFailure("finish WebGPU command buffer", err, diagnostics.Restart, true)
	}
	defer commandsBuffer.Release()
	if _, err := r.device.Queue().Submit(commandsBuffer); err != nil {
		return rendererFailure("submit WebGPU command buffer", err, diagnostics.Restart, true)
	}
	return nil
}

func (r *Renderer) submitBatch(pass *wgpu.RenderPassEncoder, batch batch, width, height, logicalWidth, logicalHeight int) (*wgpu.Buffer, error) {
	if len(batch.vertices) == 0 {
		return nil, nil
	}
	pipeline, _, err := r.pipelines.Pipeline(shader.Request{Asset: shader.Sprite2DAsset, Blend: shader.BlendSourceOver, Sampling: shader.SamplingNearest, TargetFormat: r.format.String(), TargetSampleCount: 1})
	if err != nil {
		return nil, err
	}
	native, ok := pipeline.(*wgpu.RenderPipeline)
	if !ok || native == nil {
		return nil, rendererFailure("bind WebGPU pipeline", fmt.Errorf("private pipeline cache returned %T", pipeline), diagnostics.Restart, true)
	}
	data := encodeVertices(batch.vertices)
	buffer, err := r.device.CreateBuffer(&wgpu.BufferDescriptor{Label: "72 sprite vertices", Size: uint64(len(data)), Usage: wgpu.BufferUsageVertex | wgpu.BufferUsageCopyDst})
	if err != nil {
		return nil, rendererFailure("create WebGPU vertex buffer", err, diagnostics.Restart, true)
	}
	if err := r.device.Queue().WriteBuffer(buffer, 0, data); err != nil {
		buffer.Release()
		return nil, rendererFailure("upload WebGPU vertex buffer", err, diagnostics.Restart, true)
	}
	if batch.clip != nil {
		x, y, clippedWidth, clippedHeight, ok := scissor(*batch.clip, width, height, logicalWidth, logicalHeight)
		if !ok {
			buffer.Release()
			return nil, nil
		}
		pass.SetScissorRect(x, y, clippedWidth, clippedHeight)
	} else {
		pass.SetScissorRect(0, 0, uint32(width), uint32(height))
	}
	pass.SetPipeline(native)
	pass.SetBindGroup(0, batch.texture.bind, nil)
	pass.SetVertexBuffer(0, buffer, 0)
	pass.Draw(uint32(len(batch.vertices)), 1, 0, 0)
	return buffer, nil
}

func (r *Renderer) batches(frame render.Frame, commands []render.Command, width, height int) ([]batch, error) {
	result := make([]batch, 0)
	appendVertices := func(resource *textureResource, clip *render.Rect, vertices []vertex) {
		if len(vertices) == 0 {
			return
		}
		if count := len(result); count > 0 && result[count-1].texture == resource && equalClip(result[count-1].clip, clip) {
			result[count-1].vertices = append(result[count-1].vertices, vertices...)
			return
		}
		result = append(result, batch{texture: resource, clip: copyClip(clip), vertices: vertices})
	}
	for _, command := range commands {
		if command.Kind == render.Clear {
			continue
		}
		clip, clipped := command.Clip()
		var clipPtr *render.Rect
		if clipped {
			clipPtr = &clip
		}
		offset := render.Vec2{}
		if command.Space == render.WorldSpace {
			offset = render.Vec2{X: -frame.Camera.Position.X, Y: -frame.Camera.Position.Y}
		}
		switch command.Kind {
		case render.SpriteCommand:
			sprite, ok := command.Payload.(render.Sprite)
			if !ok {
				return nil, rendererFailure("translate WebGPU sprite", fmt.Errorf("sprite command has payload %T", command.Payload), diagnostics.CorrectInput, false)
			}
			resource, err := r.texture(frame.Textures, sprite.Texture)
			if err != nil {
				return nil, rendererFailure("translate WebGPU sprite", err, diagnostics.CorrectInput, false)
			}
			vertices, err := spriteVertices(sprite, resource.width, resource.height, offset, width, height)
			if err != nil {
				return nil, rendererFailure("translate WebGPU sprite", err, diagnostics.CorrectInput, false)
			}
			appendVertices(resource, clipPtr, vertices)
		case render.TileMapCommand:
			tiles, ok := command.Payload.(render.TileMap)
			if !ok {
				return nil, rendererFailure("translate WebGPU tile map", fmt.Errorf("tile map command has payload %T", command.Payload), diagnostics.CorrectInput, false)
			}
			resource, err := r.texture(frame.Textures, tiles.Texture)
			if err != nil {
				return nil, rendererFailure("translate WebGPU tile map", err, diagnostics.CorrectInput, false)
			}
			vertices, err := tileVertices(tiles, resource.width, resource.height, offset, width, height)
			if err != nil {
				return nil, rendererFailure("translate WebGPU tile map", err, diagnostics.CorrectInput, false)
			}
			appendVertices(resource, clipPtr, vertices)
		case render.FillRect, render.StrokeRect, render.FillCircle, render.StrokeCircle, render.StrokeLine:
			vertices, err := primitiveVertices(command, offset, width, height)
			if err != nil {
				return nil, rendererFailure("translate WebGPU primitive", err, diagnostics.CorrectInput, false)
			}
			appendVertices(r.whiteTexture, clipPtr, vertices)
		case render.Text:
			value, ok := command.Payload.(render.TextDraw)
			if !ok {
				return nil, rendererFailure("translate WebGPU text", fmt.Errorf("text command has payload %T", command.Payload), diagnostics.CorrectInput, false)
			}
			textBatches, err := r.textBatches(value, offset, clipPtr, width, height)
			if err != nil {
				return nil, rendererFailure("translate WebGPU text", err, diagnostics.CorrectInput, false)
			}
			for _, textBatch := range textBatches {
				appendVertices(textBatch.texture, textBatch.clip, textBatch.vertices)
			}
		default:
			return nil, rendererFailure("translate WebGPU frame", fmt.Errorf("unsupported render command %d", command.Kind), diagnostics.CorrectInput, false)
		}
	}
	return result, nil
}

func (r *Renderer) texture(store *render.TextureStore, handle render.Texture) (*textureResource, error) {
	if store == nil {
		return nil, fmt.Errorf("texture %d is not available without an engine texture store", handle.ID)
	}
	revision, target, ok := store.Revision(handle)
	if !ok {
		return nil, fmt.Errorf("texture %d is not registered", handle.ID)
	}
	if target {
		return r.renderTarget(store, render.RenderTarget{Texture: handle})
	}
	if cached := r.textures[handle.ID]; cached != nil && cached.revision == revision {
		return cached, nil
	}
	source, ok := store.Source(handle)
	if !ok {
		return nil, fmt.Errorf("texture %d is not registered", handle.ID)
	}
	resource, err := r.createTexture(source.Image, source.Revision, fmt.Sprintf("72 texture %d", handle.ID))
	if err != nil {
		return nil, err
	}
	if previous := r.textures[handle.ID]; previous != nil {
		previous.release()
	}
	r.textures[handle.ID] = resource
	r.textureUploads++
	return resource, nil
}

func (r *Renderer) renderTarget(store *render.TextureStore, target render.RenderTarget) (*textureResource, error) {
	if target.Texture.ID == 0 {
		return nil, fmt.Errorf("render target must not be zero")
	}
	revision, isTarget, ok := store.Revision(target.Texture)
	if !ok || !isTarget {
		return nil, fmt.Errorf("render target texture %d is not registered", target.Texture.ID)
	}
	if cached := r.textures[target.Texture.ID]; cached != nil {
		return cached, nil
	}
	source, ok := store.Source(target.Texture)
	if !ok || !source.RenderTarget {
		return nil, fmt.Errorf("render target texture %d is not registered", target.Texture.ID)
	}
	resource, err := r.createTexture(source.Image, revision, fmt.Sprintf("72 render target %d", target.Texture.ID))
	if err != nil {
		return nil, err
	}
	r.textures[target.Texture.ID] = resource
	r.textureUploads++
	return resource, nil
}

func (r *Renderer) createTexture(source render.Image, revision uint64, label string) (*textureResource, error) {
	if source.Width <= 0 || source.Height <= 0 || len(source.Pixels) != source.Width*source.Height*4 {
		return nil, fmt.Errorf("texture source must be a valid RGBA8 image")
	}
	texture, err := r.device.CreateTexture(&wgpu.TextureDescriptor{Label: label, Size: wgpu.Extent3D{Width: uint32(source.Width), Height: uint32(source.Height), DepthOrArrayLayers: 1}, MipLevelCount: 1, SampleCount: 1, Dimension: wgpu.TextureDimension2D, Format: wgpu.TextureFormatRGBA8Unorm, Usage: wgpu.TextureUsageTextureBinding | wgpu.TextureUsageCopyDst | wgpu.TextureUsageRenderAttachment})
	if err != nil {
		return nil, err
	}
	view, err := r.device.CreateTextureView(texture, &wgpu.TextureViewDescriptor{})
	if err != nil {
		texture.Release()
		return nil, err
	}
	sampler, err := r.device.CreateSampler(&wgpu.SamplerDescriptor{Label: label + " sampler", AddressModeU: gputypes.AddressModeClampToEdge, AddressModeV: gputypes.AddressModeClampToEdge, AddressModeW: gputypes.AddressModeClampToEdge, MagFilter: gputypes.FilterModeNearest, MinFilter: gputypes.FilterModeNearest, MipmapFilter: gputypes.FilterModeNearest, Anisotropy: 1})
	if err != nil {
		view.Release()
		texture.Release()
		return nil, err
	}
	bind, err := r.device.CreateBindGroup(&wgpu.BindGroupDescriptor{Label: label + " bind group", Layout: r.bindGroupLayout, Entries: []wgpu.BindGroupEntry{{Binding: 0, TextureView: view}, {Binding: 1, Sampler: sampler}}})
	if err != nil {
		sampler.Release()
		view.Release()
		texture.Release()
		return nil, err
	}
	sampler.Release()
	if err := r.device.Queue().WriteTexture(&wgpu.ImageCopyTexture{Texture: texture}, source.Pixels, &wgpu.ImageDataLayout{BytesPerRow: uint32(source.Width * 4), RowsPerImage: uint32(source.Height)}, &wgpu.Extent3D{Width: uint32(source.Width), Height: uint32(source.Height), DepthOrArrayLayers: 1}); err != nil {
		bind.Release()
		view.Release()
		texture.Release()
		return nil, err
	}
	return &textureResource{texture: texture, view: view, bind: bind, width: source.Width, height: source.Height, revision: revision}, nil
}

func (r *Renderer) atlasTexture(atlas *render.GlyphAtlas, page int) (*textureResource, error) {
	image, revision, ok := atlas.Page(page)
	if !ok {
		return nil, fmt.Errorf("glyph atlas page %d is unavailable", page)
	}
	key := atlasPageKey{atlas: atlas, page: page}
	if cached := r.atlasPages[key]; cached != nil && cached.revision == revision {
		return cached, nil
	}
	resource, err := r.createTexture(image, revision, "72 glyph atlas page")
	if err != nil {
		return nil, err
	}
	if previous := r.atlasPages[key]; previous != nil {
		previous.release()
	}
	r.atlasPages[key] = resource
	r.textureUploads++
	return resource, nil
}

func (r *Renderer) basicGlyph(value rune) (*textureResource, float64, error) {
	if cached := r.basicGlyphs[value]; cached != nil {
		return cached, basicAdvance(value), nil
	}
	canvas := image.NewNRGBA(image.Rect(0, 0, 8, defaultFontSize))
	drawer := &font.Drawer{Dst: canvas, Src: image.NewUniform(color.NRGBA{R: 255, G: 255, B: 255, A: 255}), Face: basicfont.Face7x13, Dot: fixed.P(0, defaultFontSize)}
	drawer.DrawString(string(value))
	portable, err := render.NewImage(canvas.Bounds().Dx(), canvas.Bounds().Dy(), canvas.Pix)
	if err != nil {
		return nil, 0, err
	}
	resource, err := r.createTexture(portable, 1, "72 basic font glyph")
	if err != nil {
		return nil, 0, err
	}
	r.basicGlyphs[value] = resource
	r.textureUploads++
	return resource, basicAdvance(value), nil
}

func basicAdvance(value rune) float64 {
	advance, ok := basicfont.Face7x13.GlyphAdvance(value)
	if !ok {
		return 7
	}
	return float64(advance) / 64
}

func (r *Renderer) textBatches(value render.TextDraw, offset render.Vec2, clip *render.Rect, width, height int) ([]batch, error) {
	result := make([]batch, 0)
	pen := value.Position.X + offset.X
	baseline := value.Position.Y + offset.Y
	for _, runeValue := range value.Value {
		var resource *textureResource
		var source, bounds render.Rect
		var advance float64
		if value.Atlas == nil {
			var err error
			resource, advance, err = r.basicGlyph(runeValue)
			if err != nil {
				return nil, err
			}
			source = render.Rect{W: float64(resource.width), H: float64(resource.height)}
			bounds = render.Rect{X: pen, Y: baseline - defaultFontSize, W: source.W, H: source.H}
		} else {
			glyph, err := value.Atlas.Glyph(runeValue)
			if err != nil {
				return nil, fmt.Errorf("resolve glyph %q: %w", runeValue, err)
			}
			advance = glyph.Advance
			if glyph.Source.W == 0 || glyph.Source.H == 0 {
				pen += advance
				continue
			}
			resource, err = r.atlasTexture(value.Atlas, glyph.Page)
			if err != nil {
				return nil, err
			}
			source = glyph.Source
			bounds = render.Rect{X: pen + glyph.Offset.X, Y: baseline + glyph.Offset.Y, W: glyph.Source.W, H: glyph.Source.H}
		}
		sprite := render.Sprite{Source: source, Bounds: bounds, Tint: value.Color}
		vertices, err := spriteVertices(sprite, resource.width, resource.height, render.Vec2{}, width, height)
		if err != nil {
			return nil, err
		}
		if count := len(result); count > 0 && result[count-1].texture == resource && equalClip(result[count-1].clip, clip) {
			result[count-1].vertices = append(result[count-1].vertices, vertices...)
		} else {
			result = append(result, batch{texture: resource, clip: copyClip(clip), vertices: vertices})
		}
		pen += advance
	}
	return result, nil
}

func (r *Renderer) pruneResources(store *render.TextureStore) {
	if store == nil {
		return
	}
	for id, resource := range r.textures {
		if _, _, ok := store.Revision(render.Texture{ID: id}); ok {
			continue
		}
		resource.release()
		delete(r.textures, id)
	}
}

func (r *Renderer) cacheStats() (uint64, uint64) {
	var entries, bytes uint64
	add := func(resource *textureResource) {
		if resource == nil {
			return
		}
		entries++
		bytes += uint64(resource.width) * uint64(resource.height) * 4
	}
	for _, resource := range r.textures {
		add(resource)
	}
	for _, resource := range r.atlasPages {
		add(resource)
	}
	for _, resource := range r.basicGlyphs {
		add(resource)
	}
	add(r.whiteTexture)
	return entries, bytes
}

// Close releases every binding-private resource. It is idempotent.
func (r *Renderer) Close() {
	if r == nil || r.closed {
		return
	}
	r.closed = true
	for _, resource := range r.textures {
		resource.release()
	}
	for _, resource := range r.atlasPages {
		resource.release()
	}
	for _, resource := range r.basicGlyphs {
		resource.release()
	}
	if r.whiteTexture != nil {
		r.whiteTexture.release()
	}
	for _, pipeline := range r.nativePipelines {
		pipeline.Release()
	}
	if r.pipelineLayout != nil {
		r.pipelineLayout.Release()
	}
	if r.bindGroupLayout != nil {
		r.bindGroupLayout.Release()
	}
	if r.surface != nil {
		r.surface.Release()
	}
	if r.device != nil {
		r.device.Release()
	}
	if r.adapter != nil {
		r.adapter.Release()
	}
	if r.instance != nil {
		r.instance.Release()
	}
}

func (r *textureResource) release() {
	if r == nil {
		return
	}
	if r.bind != nil {
		r.bind.Release()
	}
	if r.view != nil {
		r.view.Release()
	}
	if r.texture != nil {
		r.texture.Release()
	}
}

func (r *Renderer) available(operation string) error {
	if r == nil || r.closed {
		return rendererFailure(operation, fmt.Errorf("renderer is closed"), diagnostics.Restart, true)
	}
	return nil
}

type shaderCompiler struct{ renderer *Renderer }

func (c shaderCompiler) ValidateWGSL(asset shader.Asset) error {
	module, err := c.renderer.device.CreateShaderModule(&wgpu.ShaderModuleDescriptor{Label: asset.Name + "@" + asset.Version, WGSL: asset.Source})
	if err != nil {
		return err
	}
	module.Release()
	return nil
}

func (c shaderCompiler) CreatePipeline(descriptor shader.Descriptor) (any, error) {
	module, err := c.renderer.device.CreateShaderModule(&wgpu.ShaderModuleDescriptor{Label: descriptor.Asset.Name + "@" + descriptor.Asset.Version, WGSL: descriptor.Asset.Source})
	if err != nil {
		return nil, err
	}
	defer module.Release()
	pipeline, err := c.renderer.device.CreateRenderPipeline(&wgpu.RenderPipelineDescriptor{
		Label:       descriptor.Asset.Name + " pipeline",
		Layout:      c.renderer.pipelineLayout,
		Vertex:      wgpu.VertexState{Module: module, EntryPoint: "vs_main", Buffers: []gputypes.VertexBufferLayout{{ArrayStride: vertexStride, StepMode: gputypes.VertexStepModeVertex, Attributes: []gputypes.VertexAttribute{{Format: gputypes.VertexFormatFloat32x2, Offset: 0, ShaderLocation: 0}, {Format: gputypes.VertexFormatFloat32x2, Offset: 8, ShaderLocation: 1}, {Format: gputypes.VertexFormatFloat32x4, Offset: 16, ShaderLocation: 2}}}}},
		Primitive:   gputypes.PrimitiveState{Topology: gputypes.PrimitiveTopologyTriangleList},
		Multisample: gputypes.DefaultMultisampleState(),
		Fragment:    &wgpu.FragmentState{Module: module, EntryPoint: "fs_main", Targets: []gputypes.ColorTargetState{{Format: c.renderer.format, Blend: blendState(descriptor.Blend), WriteMask: gputypes.ColorWriteMaskAll}}},
	})
	if err != nil {
		return nil, err
	}
	c.renderer.nativePipelines = append(c.renderer.nativePipelines, pipeline)
	return pipeline, nil
}

func blendState(value shader.BlendState) *gputypes.BlendState {
	component := func(input shader.BlendComponent) gputypes.BlendComponent {
		factor := func(value shader.BlendFactor) gputypes.BlendFactor {
			switch value {
			case shader.BlendFactorZero:
				return gputypes.BlendFactorZero
			case shader.BlendFactorOneMinusSourceAlpha:
				return gputypes.BlendFactorOneMinusSrcAlpha
			default:
				return gputypes.BlendFactorOne
			}
		}
		return gputypes.BlendComponent{SrcFactor: factor(input.Source), DstFactor: factor(input.Destination), Operation: gputypes.BlendOperationAdd}
	}
	return &gputypes.BlendState{Color: component(value.Color), Alpha: component(value.Alpha)}
}

func orderedCommands(commands []render.Command) []render.Command {
	sort.SliceStable(commands, func(left, right int) bool {
		if commands[left].Kind == render.Clear {
			return true
		}
		if commands[right].Kind == render.Clear {
			return false
		}
		return commands[left].Layer < commands[right].Layer
	})
	return commands
}

func colorValue(value render.Color) gputypes.Color {
	return gputypes.Color{R: float64(value.R) / 255, G: float64(value.G) / 255, B: float64(value.B) / 255, A: float64(value.A) / 255}
}

func copyClip(clip *render.Rect) *render.Rect {
	if clip == nil {
		return nil
	}
	value := *clip
	return &value
}

func equalClip(left, right *render.Rect) bool {
	return left == nil && right == nil || left != nil && right != nil && *left == *right
}

func scissor(clip render.Rect, width, height, logicalWidth, logicalHeight int) (uint32, uint32, uint32, uint32, bool) {
	left := max(0, int(math.Floor(clip.X*float64(width)/float64(logicalWidth))))
	top := max(0, int(math.Floor(clip.Y*float64(height)/float64(logicalHeight))))
	right := min(width, int(math.Ceil((clip.X+clip.W)*float64(width)/float64(logicalWidth))))
	bottom := min(height, int(math.Ceil((clip.Y+clip.H)*float64(height)/float64(logicalHeight))))
	if left >= right || top >= bottom {
		return 0, 0, 0, 0, false
	}
	return uint32(left), uint32(top), uint32(right - left), uint32(bottom - top), true
}

func rendererFailure(operation string, cause error, recovery diagnostics.Recovery, terminal bool) error {
	return diagnostics.NewFailure(diagnostics.RendererSubsystem, operation, cause, recovery, terminal)
}

var _ render.Backend = (*Renderer)(nil)
var _ render.TargetBackend = (*Renderer)(nil)
