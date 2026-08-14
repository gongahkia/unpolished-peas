package render

import (
	"sort"
	"time"

	"github.com/gongahkia/72/engine/diagnostics"
)

// FrameMetrics is a backend-neutral summary of one render submission.
// CompatibleSpriteRuns identifies contiguous, order-preserving sprite groups
// that share texture, coordinate space, and clip state. It is a
// batching opportunity, not a claim about GPU draw calls. NativeTextureBytes
// is an optional backend estimate based on known texture dimensions;
// NativeBufferBytes is the capacity of renderer-owned dynamic buffers. Neither
// includes driver allocations, command buffers, or transient memory.
type FrameMetrics struct {
	Commands, ClearCommands                       uint64
	Sprites, TileMaps, Primitives, Texts          uint64
	TileCells, VisibleTiles, CompatibleSpriteRuns uint64
	Batches, DrawCalls                            uint64
	PortableTextures, PortableTextureBytes        uint64
	RenderTargets, RenderTargetBytes              uint64
	TextureUploads, NativeTextureEntries          uint64
	NativeTextureBytes, NativeBufferBytes         uint64
	NativePipelineEntries                         uint64
	Duration                                      time.Duration
}

// CollectFrameMetrics summarizes frame against a screen-space target
// viewport. Tile cell visibility accounts for camera translation and any
// command clip. Invalid or empty viewports still return command and texture
// counts, but report no visible tile cells.
func CollectFrameMetrics(frame Frame, viewport Rect) FrameMetrics {
	metrics := FrameMetrics{}
	if frame.Textures != nil {
		textures := frame.Textures.Stats()
		metrics.PortableTextures = textures.Count
		metrics.PortableTextureBytes = textures.Bytes
		metrics.RenderTargets = textures.RenderTargetCount
		metrics.RenderTargetBytes = textures.RenderTargetBytes
	}
	if frame.Queue == nil {
		return metrics
	}

	commands := orderedCommands(frame.Queue.Commands())
	metrics.Commands = uint64(len(commands))
	var previousSprite Command
	hasPreviousSprite := false
	for _, command := range commands {
		switch command.Kind {
		case Clear:
			metrics.ClearCommands++
			hasPreviousSprite = false
		case SpriteCommand:
			metrics.Sprites++
			if !hasPreviousSprite || !compatibleSpriteCommands(previousSprite, command) {
				metrics.CompatibleSpriteRuns++
			}
			previousSprite, hasPreviousSprite = command, true
		case TileMapCommand:
			metrics.TileMaps++
			hasPreviousSprite = false
			tiles, ok := command.Payload.(TileMap)
			if !ok {
				continue
			}
			metrics.TileCells += nonEmptyTileCount(tiles, TileRange{Columns: tiles.Columns, Rows: tileRows(tiles)})
			if visible, ok := commandViewport(command, frame.Camera, viewport); ok {
				metrics.VisibleTiles += nonEmptyTileCount(tiles, tiles.VisibleRange(visible))
			}
		case FillRect, StrokeRect, FillCircle, StrokeCircle, StrokeLine:
			metrics.Primitives++
			hasPreviousSprite = false
		case Text:
			metrics.Texts++
			hasPreviousSprite = false
		default:
			hasPreviousSprite = false
		}
	}
	return metrics
}

// RecordInto aggregates counters and refreshes point-in-time resource gauges
// in registry. A nil registry is ignored so direct backend users need not
// allocate diagnostics infrastructure.
func (m FrameMetrics) RecordInto(registry *diagnostics.Registry) {
	if registry == nil {
		return
	}
	_ = registry.Add("renderer.frames", 1)
	_ = registry.Record("renderer.frame_time", m.Duration)
	_ = registry.Add("renderer.commands", m.Commands)
	_ = registry.Add("renderer.clear_commands", m.ClearCommands)
	_ = registry.Add("renderer.sprite_commands", m.Sprites)
	_ = registry.Add("renderer.tile_map_commands", m.TileMaps)
	_ = registry.Add("renderer.primitive_commands", m.Primitives)
	_ = registry.Add("renderer.text_commands", m.Texts)
	_ = registry.Add("renderer.tile_cells", m.TileCells)
	_ = registry.Add("renderer.visible_tiles", m.VisibleTiles)
	_ = registry.Add("renderer.compatible_sprite_runs", m.CompatibleSpriteRuns)
	_ = registry.Add("renderer.batches", m.Batches)
	_ = registry.Add("renderer.draw_calls", m.DrawCalls)
	_ = registry.Add("renderer.texture_uploads", m.TextureUploads)
	_ = registry.Set("renderer.portable_texture_count", m.PortableTextures)
	_ = registry.Set("renderer.portable_texture_bytes", m.PortableTextureBytes)
	_ = registry.Set("renderer.render_target_count", m.RenderTargets)
	_ = registry.Set("renderer.render_target_bytes", m.RenderTargetBytes)
	_ = registry.Set("renderer.native_texture_entries", m.NativeTextureEntries)
	_ = registry.Set("renderer.native_texture_bytes", m.NativeTextureBytes)
	_ = registry.Set("renderer.native_buffer_bytes", m.NativeBufferBytes)
	_ = registry.Set("renderer.native_pipeline_entries", m.NativePipelineEntries)
}

func orderedCommands(commands []Command) []Command {
	sort.SliceStable(commands, func(left, right int) bool {
		if commands[left].Kind == Clear {
			return true
		}
		if commands[right].Kind == Clear {
			return false
		}
		return commands[left].Layer < commands[right].Layer
	})
	return commands
}

func compatibleSpriteCommands(left, right Command) bool {
	if left.Kind != SpriteCommand || right.Kind != SpriteCommand || left.Space != right.Space || left.Layer != right.Layer || !equalCommandClip(left, right) {
		return false
	}
	leftSprite, leftOK := left.Payload.(Sprite)
	rightSprite, rightOK := right.Payload.(Sprite)
	return leftOK && rightOK && leftSprite.Texture == rightSprite.Texture
}

func equalCommandClip(left, right Command) bool {
	leftClip, leftOK := left.Clip()
	rightClip, rightOK := right.Clip()
	return leftOK == rightOK && (!leftOK || leftClip == rightClip)
}

func commandViewport(command Command, camera Camera, viewport Rect) (Rect, bool) {
	if !finiteRect(viewport) || viewport.W <= 0 || viewport.H <= 0 {
		return Rect{}, false
	}
	if clip, ok := command.Clip(); ok {
		viewport = intersectRects(viewport, clip)
		if viewport.W <= 0 || viewport.H <= 0 {
			return Rect{}, false
		}
	}
	offset, err := commandOffset(camera, command.Space)
	if err != nil {
		return Rect{}, false
	}
	return translateRect(viewport, Vec2{X: -offset.X, Y: -offset.Y}), true
}

func tileRows(tiles TileMap) int {
	if tiles.Columns <= 0 {
		return 0
	}
	return (len(tiles.Tiles) + tiles.Columns - 1) / tiles.Columns
}

func nonEmptyTileCount(tiles TileMap, region TileRange) uint64 {
	if region.Columns <= 0 || region.Rows <= 0 || tiles.Columns <= 0 {
		return 0
	}
	var count uint64
	for row := region.Row; row < region.Row+region.Rows; row++ {
		for column := region.Column; column < region.Column+region.Columns; column++ {
			index := row*tiles.Columns + column
			if index >= 0 && index < len(tiles.Tiles) && tiles.Tiles[index] >= 0 {
				count++
			}
		}
	}
	return count
}
