const std = @import("std");
const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const Rect = @import("math.zig").Rect;
const Vec2 = @import("math.zig").Vec2;

const max_map_bytes = 64 * 1024 * 1024;

pub const Projection = enum { orthogonal, isometric };
pub const LayerKind = enum { tiles, int_grid, group, objects };
pub const TileSourceKind = enum { grid_image, image_collection, atlas_frames };

pub const PropertyValue = union(enum) {
    string: []u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

pub const Property = struct {
    name: []u8,
    value: PropertyValue,

    fn deinit(self: *Property, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        switch (self.value) {
            .string => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }
};

pub const ObjectShape = union(enum) {
    rectangle,
    ellipse,
    point,
    polygon: []Vec2,
    polyline: []Vec2,
};

pub const MapObject = struct {
    id: []u8,
    name: []u8,
    class_name: []u8,
    bounds: Rect,
    shape: ObjectShape,
    properties: []Property = &.{},

    fn deinit(self: *MapObject, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.class_name);
        switch (self.shape) {
            .polygon => |points| allocator.free(points),
            .polyline => |points| allocator.free(points),
            else => {},
        }
        for (self.properties) |*property| property.deinit(allocator);
        allocator.free(self.properties);
        self.* = undefined;
    }
};

pub const TileFlags = packed struct(u8) {
    flip_x: bool = false,
    flip_y: bool = false,
    diagonal: bool = false,
    _padding: u5 = 0,
};

pub const Tile = struct {
    tileset: u16,
    id: u32,
    flags: TileFlags = .{},
    opacity: f32 = 1,
};

pub const TileAnimationFrame = struct {
    tile_id: u32,
    duration: f32,
};

pub const TileAnimation = struct {
    tile_id: u32,
    frames: []TileAnimationFrame,
};

pub const TileMapDependencyKind = enum { tileset, image, overlay };

pub const TileMapDependency = struct {
    kind: TileMapDependencyKind,
    path: []u8,
};

pub const TileImageResolver = struct {
    context: *const anyopaque,
    resolve: *const fn (context: *const anyopaque, tileset: u16, tile_id: u32) ?Image,
};

pub const TileStack = struct {
    items: std.ArrayListUnmanaged(Tile) = .{},

    fn deinit(self: *TileStack, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.* = undefined;
    }
};

pub const ChunkCoord = struct { x: i32, y: i32 };

pub const TileSet = struct {
    name: []u8,
    kind: TileSourceKind,
    path: []u8,
    tile_size: Vec2,
    margin: u32 = 0,
    spacing: u32 = 0,
    image_paths: []?[]u8 = &.{},
    atlas_frames: [][]u8 = &.{},
    animations: []TileAnimation = &.{},

    fn deinit(self: *TileSet, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        for (self.image_paths) |image_path| if (image_path) |value| allocator.free(value);
        allocator.free(self.image_paths);
        for (self.atlas_frames) |frame| allocator.free(frame);
        allocator.free(self.atlas_frames);
        for (self.animations) |animation| allocator.free(animation.frames);
        allocator.free(self.animations);
        self.* = undefined;
    }
};

pub const Chunk = struct {
    coord: ChunkCoord,
    tiles: []TileStack,
    int_grid: []i32,

    fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        for (self.tiles) |*stack| stack.deinit(allocator);
        allocator.free(self.tiles);
        allocator.free(self.int_grid);
        self.* = undefined;
    }
};

pub const TileMapLayer = struct {
    name: []u8,
    kind: LayerKind = .tiles,
    parent: ?u32 = null,
    visible: bool = true,
    opacity: f32 = 1,
    offset: Vec2 = .{},
    parallax: Vec2 = .{ .x = 1, .y = 1 },
    chunks: std.ArrayListUnmanaged(Chunk) = .{},
    objects: std.ArrayListUnmanaged(MapObject) = .{},
    properties: []Property = &.{},

    fn deinit(self: *TileMapLayer, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.chunks.items) |*chunk| chunk.deinit(allocator);
        self.chunks.deinit(allocator);
        for (self.objects.items) |*map_object| map_object.deinit(allocator);
        self.objects.deinit(allocator);
        for (self.properties) |*property| property.deinit(allocator);
        allocator.free(self.properties);
        self.* = undefined;
    }
};

pub const TileMap = struct { // owns tilesets, layers, chunks, and dependencies allocated by init/load; call deinit once.
    allocator: std.mem.Allocator,
    projection: Projection = .orthogonal,
    tile_size: Vec2,
    chunk_size: u32 = 32,
    editable: bool = true,
    tilesets: std.ArrayListUnmanaged(TileSet) = .{},
    layers: std.ArrayListUnmanaged(TileMapLayer) = .{},
    dependencies: std.ArrayListUnmanaged(TileMapDependency) = .{},

    pub fn init(allocator: std.mem.Allocator, tile_size: Vec2, chunk_size: u32) !TileMap {
        if (tile_size.x <= 0 or tile_size.y <= 0 or !validChunkSize(chunk_size)) return error.InvalidMapConfig;
        return .{ .allocator = allocator, .tile_size = tile_size, .chunk_size = chunk_size };
    }

    pub fn deinit(self: *TileMap) void {
        for (self.tilesets.items) |*tileset| tileset.deinit(self.allocator);
        self.tilesets.deinit(self.allocator);
        for (self.layers.items) |*entry| entry.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        for (self.dependencies.items) |dependency| self.allocator.free(dependency.path);
        self.dependencies.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addLayer(self: *TileMap, name: []const u8, kind: LayerKind, parent: ?u32) !u32 {
        if (parent) |index| if (index >= self.layers.items.len or self.layers.items[index].kind != .group) return error.InvalidParentLayer;
        try self.layers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .kind = kind, .parent = parent });
        return @intCast(self.layers.items.len - 1);
    }

    pub fn addTileSet(self: *TileMap, name: []const u8, kind: TileSourceKind, path: []const u8, tile_size: Vec2) !u16 {
        if (tile_size.x <= 0 or tile_size.y <= 0 or self.tilesets.items.len >= std.math.maxInt(u16)) return error.InvalidTileSet;
        try self.tilesets.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .kind = kind,
            .path = try self.allocator.dupe(u8, path),
            .tile_size = tile_size,
        });
        return @intCast(self.tilesets.items.len - 1);
    }

    pub fn addDependency(self: *TileMap, kind: TileMapDependencyKind, path: []const u8) !void {
        for (self.dependencies.items) |entry| if (std.mem.eql(u8, entry.path, path)) return;
        try self.dependencies.append(self.allocator, .{ .kind = kind, .path = try self.allocator.dupe(u8, path) });
    }

    pub fn setTile(self: *TileMap, layer_index: u32, cell: ChunkCoord, tile: ?Tile) !void {
        if (!self.editable) return error.ReadOnlyMap;
        const target = self.findLayer(layer_index) orelse return error.InvalidLayer;
        if (target.kind != .tiles) return error.InvalidLayerKind;
        if (tile) |value| if (value.tileset >= self.tilesets.items.len) return error.InvalidTileSet;
        const chunk_coord = chunkFor(cell, self.chunk_size);
        const chunk = try self.ensureChunk(target, chunk_coord);
        var stack = &chunk.tiles[cellIndex(cell, self.chunk_size)];
        stack.items.clearRetainingCapacity();
        if (tile) |value| try stack.items.append(self.allocator, value);
    }

    pub fn tileAt(self: TileMap, layer_index: u32, cell: ChunkCoord) ?Tile {
        if (layer_index >= self.layers.items.len) return null;
        const target = &self.layers.items[layer_index];
        if (target.kind != .tiles) return null;
        const chunk = findChunk(target, chunkFor(cell, self.chunk_size)) orelse return null;
        const stack = &chunk.tiles[cellIndex(cell, self.chunk_size)];
        if (stack.items.items.len == 0) return null;
        return stack.items.items[stack.items.items.len - 1];
    }

    pub fn tileStackAt(self: *const TileMap, layer_index: u32, cell: ChunkCoord) []const Tile {
        if (layer_index >= self.layers.items.len) return &.{};
        const target = &self.layers.items[layer_index];
        if (target.kind != .tiles) return &.{};
        const chunk = findChunkConst(target, chunkFor(cell, self.chunk_size)) orelse return &.{};
        return chunk.tiles[cellIndex(cell, self.chunk_size)].items.items;
    }

    pub fn replaceTileStack(self: *TileMap, layer_index: u32, cell: ChunkCoord, tiles: []const Tile) !void {
        if (!self.editable) return error.ReadOnlyMap;
        const target = self.findLayer(layer_index) orelse return error.InvalidLayer;
        if (target.kind != .tiles) return error.InvalidLayerKind;
        for (tiles) |tile| if (tile.tileset >= self.tilesets.items.len) return error.InvalidTileSet;
        const chunk = try self.ensureChunk(target, chunkFor(cell, self.chunk_size));
        var stack = &chunk.tiles[cellIndex(cell, self.chunk_size)];
        stack.items.clearRetainingCapacity();
        try stack.items.appendSlice(self.allocator, tiles);
    }

    pub fn pushTile(self: *TileMap, layer_index: u32, cell: ChunkCoord, tile: Tile) !void {
        if (!self.editable) return error.ReadOnlyMap;
        if (tile.tileset >= self.tilesets.items.len) return error.InvalidTileSet;
        const target = self.findLayer(layer_index) orelse return error.InvalidLayer;
        if (target.kind != .tiles) return error.InvalidLayerKind;
        const chunk = try self.ensureChunk(target, chunkFor(cell, self.chunk_size));
        try chunk.tiles[cellIndex(cell, self.chunk_size)].items.append(self.allocator, tile);
    }

    pub fn removeTile(self: *TileMap, layer_index: u32, cell: ChunkCoord, stack_index: usize) !Tile {
        if (!self.editable) return error.ReadOnlyMap;
        const target = self.findLayer(layer_index) orelse return error.InvalidLayer;
        if (target.kind != .tiles) return error.InvalidLayerKind;
        const chunk = findChunk(target, chunkFor(cell, self.chunk_size)) orelse return error.TileNotFound;
        var stack = &chunk.tiles[cellIndex(cell, self.chunk_size)];
        if (stack_index >= stack.items.items.len) return error.TileNotFound;
        return stack.items.orderedRemove(stack_index);
    }

    pub fn setIntGrid(self: *TileMap, layer_index: u32, cell: ChunkCoord, value: i32) !void {
        if (!self.editable) return error.ReadOnlyMap;
        const target = self.findLayer(layer_index) orelse return error.InvalidLayer;
        if (target.kind != .int_grid) return error.InvalidLayerKind;
        const chunk = try self.ensureChunk(target, chunkFor(cell, self.chunk_size));
        chunk.int_grid[cellIndex(cell, self.chunk_size)] = value;
    }

    pub fn intGridAt(self: TileMap, layer_index: u32, cell: ChunkCoord) ?i32 {
        if (layer_index >= self.layers.items.len) return null;
        const target = &self.layers.items[layer_index];
        if (target.kind != .int_grid) return null;
        const chunk = findChunk(target, chunkFor(cell, self.chunk_size)) orelse return null;
        return chunk.int_grid[cellIndex(cell, self.chunk_size)];
    }

    pub fn layerObjects(self: TileMap, layer_index: u32) []const MapObject {
        if (layer_index >= self.layers.items.len) return &.{};
        return self.layers.items[layer_index].objects.items;
    }

    pub fn layerProperties(self: TileMap, layer_index: u32) []const Property {
        if (layer_index >= self.layers.items.len) return &.{};
        return self.layers.items[layer_index].properties;
    }

    pub fn cellToWorld(self: TileMap, cell: ChunkCoord) Vec2 {
        return switch (self.projection) {
            .orthogonal => .{ .x = @as(f32, @floatFromInt(cell.x)) * self.tile_size.x, .y = @as(f32, @floatFromInt(cell.y)) * self.tile_size.y },
            .isometric => .{
                .x = @as(f32, @floatFromInt(cell.x - cell.y)) * self.tile_size.x / 2,
                .y = @as(f32, @floatFromInt(cell.x + cell.y)) * self.tile_size.y / 2,
            },
        };
    }

    pub fn worldToCell(self: TileMap, world: Vec2) ChunkCoord {
        return switch (self.projection) {
            .orthogonal => .{ .x = @intFromFloat(@floor(world.x / self.tile_size.x)), .y = @intFromFloat(@floor(world.y / self.tile_size.y)) },
            .isometric => .{
                .x = @intFromFloat(@floor(world.y / self.tile_size.y + world.x / self.tile_size.x)),
                .y = @intFromFloat(@floor(world.y / self.tile_size.y - world.x / self.tile_size.x)),
            },
        };
    }

    pub fn drawDebug(self: TileMap, world: CameraCanvas) void {
        for (self.layers.items, 0..) |layer, layer_index| {
            const state = self.layerState(@intCast(layer_index));
            if (layer.kind != .tiles or !state.visible) continue;
            const camera = world.camera.parallax(state.parallax);
            const canvas = CameraCanvas.init(world.canvas, &camera);
            for (layer.chunks.items) |chunk| {
                for (chunk.tiles, 0..) |stack, index| {
                    const size: i32 = @intCast(self.chunk_size);
                    const local_x: i32 = @intCast(index % self.chunk_size);
                    const local_y: i32 = @intCast(index / self.chunk_size);
                    const cell = ChunkCoord{ .x = chunk.coord.x * size + local_x, .y = chunk.coord.y * size + local_y };
                    const position = self.cellToWorld(cell).add(state.offset);
                    for (stack.items.items) |value| {
                        const color = debugTileColor(value, @intCast(layer_index));
                        canvas.fillRect(Rect.init(position.x, position.y, self.tile_size.x, self.tile_size.y), color);
                    }
                }
            }
        }
    }

    pub fn drawImages(self: TileMap, world: CameraCanvas, images: []const Image) void {
        self.drawImagesAt(world, images, 0);
    }

    pub fn drawImagesAt(self: TileMap, world: CameraCanvas, images: []const Image, time: f32) void {
        if (images.len < self.tilesets.items.len) return;
        const Adapter = struct {
            images: []const Image,
            fn resolve(context: *const anyopaque, tileset: u16, _: u32) ?Image {
                const self_adapter: *const @This() = @ptrCast(@alignCast(context));
                return self_adapter.images[tileset];
            }
        };
        const adapter = Adapter{ .images = images };
        self.drawResolvedImagesAt(world, .{ .context = &adapter, .resolve = Adapter.resolve }, time);
    }

    pub fn drawResolvedImagesAt(self: TileMap, world: CameraCanvas, resolver: TileImageResolver, time: f32) void {
        for (self.layers.items, 0..) |layer, layer_index| {
            const state = self.layerState(@intCast(layer_index));
            if (layer.kind != .tiles or !state.visible) continue;
            const camera = world.camera.parallax(state.parallax);
            const canvas = CameraCanvas.init(world.canvas, &camera);
            for (layer.chunks.items) |chunk| {
                for (chunk.tiles, 0..) |stack, index| {
                    const size: i32 = @intCast(self.chunk_size);
                    const local_x: i32 = @intCast(index % self.chunk_size);
                    const local_y: i32 = @intCast(index / self.chunk_size);
                    const position = self.cellToWorld(.{ .x = chunk.coord.x * size + local_x, .y = chunk.coord.y * size + local_y }).add(state.offset);
                    for (stack.items.items) |value| {
                        const resolved = animatedTile(self.tilesets.items[value.tileset], value, time);
                        const tileset = self.tilesets.items[resolved.tileset];
                        const image = resolver.resolve(resolver.context, resolved.tileset, resolved.id) orelse continue;
                        const opacity = Color.rgba(255, 255, 255, @intFromFloat(@round(@max(@as(f32, 0), @min(@as(f32, 1), state.opacity * resolved.opacity)) * 255)));
                        if (tileset.kind == .image_collection) {
                            canvas.drawImageRegionTransformed(image, Rect.init(0, 0, @floatFromInt(image.width), @floatFromInt(image.height)), Rect.init(position.x, position.y, self.tile_size.x, self.tile_size.y), opacity, resolved.flags.flip_x, resolved.flags.flip_y, resolved.flags.diagonal);
                            continue;
                        }
                        if (tileset.kind != .grid_image) continue;
                        const available_width = @as(f32, @floatFromInt(image.width)) - 2 * @as(f32, @floatFromInt(tileset.margin)) + @as(f32, @floatFromInt(tileset.spacing));
                        const stride = tileset.tile_size.x + @as(f32, @floatFromInt(tileset.spacing));
                        const columns = @max(@as(u32, 1), @as(u32, @intFromFloat(@floor(available_width / stride))));
                        const source_col = resolved.id % columns;
                        const source_row = resolved.id / columns;
                        const source = Rect.init(@as(f32, @floatFromInt(tileset.margin)) + @as(f32, @floatFromInt(source_col)) * (tileset.tile_size.x + @as(f32, @floatFromInt(tileset.spacing))), @as(f32, @floatFromInt(tileset.margin)) + @as(f32, @floatFromInt(source_row)) * (tileset.tile_size.y + @as(f32, @floatFromInt(tileset.spacing))), tileset.tile_size.x, tileset.tile_size.y);
                        canvas.drawImageRegionTransformed(image, source, Rect.init(position.x, position.y, self.tile_size.x, self.tile_size.y), opacity, resolved.flags.flip_x, resolved.flags.flip_y, resolved.flags.diagonal);
                    }
                }
            }
        }
    }

    pub fn applyOverlay(self: *TileMap, path: []const u8) !void {
        const bytes = try std.fs.cwd().readFileAlloc(self.allocator, path, max_map_bytes);
        defer self.allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        const root = try object(parsed.value);
        if (!std.mem.eql(u8, try string(root.get("format") orelse return error.InvalidTileOverlay), "unpolished-peas-tile-overlay")) return error.InvalidTileOverlay;
        if (try u32Value(root.get("version") orelse return error.InvalidTileOverlay) != 1) return error.UnsupportedTileOverlay;
        for ((try array(root.get("animations") orelse return error.InvalidTileOverlay)).items) |animation_value| {
            const animation = try object(animation_value);
            const tileset = self.findTileSetByName(try string(animation.get("tileset") orelse return error.InvalidTileOverlay)) orelse return error.UnknownOverlayTileSet;
            try replaceAnimation(self.allocator, &self.tilesets.items[tileset], try u32Value(animation.get("tile") orelse return error.InvalidTileOverlay), try parseAnimationFrames(self.allocator, try array(animation.get("frames") orelse return error.InvalidTileOverlay)));
        }
    }

    fn findLayer(self: *TileMap, index: u32) ?*TileMapLayer {
        if (index >= self.layers.items.len) return null;
        return &self.layers.items[index];
    }

    fn findTileSetByName(self: *const TileMap, name: []const u8) ?usize {
        for (self.tilesets.items, 0..) |tileset, index| if (std.mem.eql(u8, tileset.name, name)) return index;
        return null;
    }

    const LayerState = struct {
        visible: bool = true,
        opacity: f32 = 1,
        offset: Vec2 = .{},
        parallax: Vec2 = .{ .x = 1, .y = 1 },
    };

    fn layerState(self: TileMap, index: u32) LayerState {
        var result = LayerState{};
        var current: ?u32 = index;
        while (current) |layer_index| {
            const layer = self.layers.items[layer_index];
            result.visible = result.visible and layer.visible;
            result.opacity *= layer.opacity;
            result.offset = result.offset.add(layer.offset);
            result.parallax = .{ .x = result.parallax.x * layer.parallax.x, .y = result.parallax.y * layer.parallax.y };
            current = layer.parent;
        }
        return result;
    }

    pub fn layerOffset(self: TileMap, index: u32) Vec2 {
        if (index >= self.layers.items.len) return .{};
        return self.layerState(index).offset;
    }

    fn ensureChunk(self: *TileMap, target: *TileMapLayer, coord: ChunkCoord) !*Chunk {
        if (findChunk(target, coord)) |chunk| return chunk;
        const count = try cellCount(self.chunk_size);
        const tiles = try self.allocator.alloc(TileStack, count);
        errdefer self.allocator.free(tiles);
        for (tiles) |*stack| stack.* = .{};
        const int_grid = try self.allocator.alloc(i32, count);
        errdefer self.allocator.free(int_grid);
        @memset(int_grid, 0);
        try target.chunks.append(self.allocator, .{ .coord = coord, .tiles = tiles, .int_grid = int_grid });
        return &target.chunks.items[target.chunks.items.len - 1];
    }
};

fn parseAnimationFrames(allocator: std.mem.Allocator, values: std.json.Array) ![]TileAnimationFrame {
    const frames = try allocator.alloc(TileAnimationFrame, values.items.len);
    errdefer allocator.free(frames);
    for (values.items, 0..) |value, index| {
        const frame = try object(value);
        const duration = try f32Value(frame.get("duration") orelse return error.InvalidTileOverlay);
        if (duration <= 0) return error.InvalidTileOverlay;
        frames[index] = .{ .tile_id = try u32Value(frame.get("tile") orelse return error.InvalidTileOverlay), .duration = duration };
    }
    if (frames.len == 0) return error.InvalidTileOverlay;
    return frames;
}

fn replaceAnimation(allocator: std.mem.Allocator, tileset: *TileSet, tile_id: u32, frames: []TileAnimationFrame) !void {
    for (tileset.animations) |*animation| {
        if (animation.tile_id != tile_id) continue;
        allocator.free(animation.frames);
        animation.frames = frames;
        return;
    }
    const next = try allocator.realloc(tileset.animations, tileset.animations.len + 1);
    next[next.len - 1] = .{ .tile_id = tile_id, .frames = frames };
    tileset.animations = next;
}

fn debugTileColor(tile: Tile, layer: u8) Color {
    const seed = tile.id *% 37 +% @as(u32, tile.tileset) *% 101 +% layer *% 53;
    return .rgb(@intCast(64 + seed % 160), @intCast(64 + (seed / 3) % 160), @intCast(64 + (seed / 7) % 160));
}

fn animatedTile(tileset: TileSet, tile: Tile, time: f32) Tile {
    for (tileset.animations) |animation| {
        if (animation.tile_id != tile.id) continue;
        var duration: f32 = 0;
        for (animation.frames) |frame| duration += frame.duration;
        if (duration <= 0) return tile;
        var cursor = @mod(@max(0, time), duration);
        for (animation.frames) |frame| {
            if (cursor < frame.duration) {
                var result = tile;
                result.id = frame.tile_id;
                return result;
            }
            cursor -= frame.duration;
        }
    }
    return tile;
}

fn validChunkSize(value: u32) bool {
    return value >= 8 and value <= 128 and std.math.isPowerOfTwo(value);
}

fn cellCount(chunk_size: u32) !usize {
    return std.math.mul(usize, chunk_size, chunk_size) catch error.InvalidMapConfig;
}

fn floorDiv(value: i32, divisor: i32) i32 {
    return @divFloor(value, divisor);
}

fn modFloor(value: i32, divisor: i32) i32 {
    return @mod(value, divisor);
}

fn chunkFor(cell: ChunkCoord, chunk_size: u32) ChunkCoord {
    const size: i32 = @intCast(chunk_size);
    return .{ .x = floorDiv(cell.x, size), .y = floorDiv(cell.y, size) };
}

fn cellIndex(cell: ChunkCoord, chunk_size: u32) usize {
    const size: i32 = @intCast(chunk_size);
    return @as(usize, @intCast(modFloor(cell.y, size))) * chunk_size + @as(usize, @intCast(modFloor(cell.x, size)));
}

fn findChunk(layer: *TileMapLayer, coord: ChunkCoord) ?*Chunk {
    for (layer.chunks.items) |*chunk| if (chunk.coord.x == coord.x and chunk.coord.y == coord.y) return chunk;
    return null;
}

fn findChunkConst(layer: *const TileMapLayer, coord: ChunkCoord) ?*const Chunk {
    for (layer.chunks.items) |*chunk| if (chunk.coord.x == coord.x and chunk.coord.y == coord.y) return chunk;
    return null;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |item| item,
        else => error.InvalidMap,
    };
}
fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |item| item,
        else => error.InvalidMap,
    };
}
fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |item| item,
        else => error.InvalidMap,
    };
}
fn u32Value(value: std.json.Value) !u32 {
    return std.math.cast(u32, try i64Value(value)) orelse error.InvalidMap;
}
fn i64Value(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |item| item,
        else => error.InvalidMap,
    };
}
fn f32Value(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| @floatCast(item),
        else => error.InvalidMap,
    };
}
test "tile map mutates signed chunks" {
    var map = try TileMap.init(std.testing.allocator, .{ .x = 8, .y = 8 }, 8);
    defer map.deinit();
    _ = try map.addTileSet("tiles", .grid_image, "tiles.png", .{ .x = 8, .y = 8 });
    const layer = try map.addLayer("ground", .tiles, null);
    try map.setTile(layer, .{ .x = -1, .y = -1 }, .{ .tileset = 0, .id = 2 });
    try std.testing.expectEqual(@as(u32, 2), map.tileAt(layer, .{ .x = -1, .y = -1 }).?.id);
    const isometric = TileMap{ .allocator = std.testing.allocator, .projection = .isometric, .tile_size = .{ .x = 8, .y = 8 } };
    try std.testing.expectEqual(Vec2.init(-4, -4), isometric.cellToWorld(.{ .x = -1, .y = 0 }));
}

test "tile map excludes legacy map loaders" {
    try std.testing.expect(!@hasDecl(TileMap, "loadNative"));
    try std.testing.expect(!@hasDecl(TileMap, "decodeNative"));
    try std.testing.expect(!@hasDecl(TileMap, "saveNative"));
    try std.testing.expect(!@hasDecl(TileMap, "writeBinary"));
    try std.testing.expect(!@hasDecl(TileMap, "loadBinary"));
    try std.testing.expect(!@hasDecl(TileMap, "loadTiled"));
    try std.testing.expect(!@hasDecl(TileMap, "loadTiledWithOptions"));
    try std.testing.expect(!@hasDecl(TileMap, "loadLdtkProject"));
    try std.testing.expect(!@hasDecl(TileMap, "loadLdtkProjectWithOptions"));
}

test "native tile rendering applies layer opacity and flip flags" {
    var map = try TileMap.init(std.testing.allocator, .{ .x = 2, .y = 1 }, 8);
    defer map.deinit();
    _ = try map.addTileSet("tiles", .grid_image, "tiles.png", .{ .x = 2, .y = 1 });
    const layer = try map.addLayer("ground", .tiles, null);
    map.layers.items[layer].opacity = 0.5;
    try map.setTile(layer, .{ .x = 0, .y = 0 }, .{ .tileset = 0, .id = 0, .flags = .{ .flip_x = true }, .opacity = 0.5 });

    var canvas = try @import("canvas.zig").Canvas.init(std.testing.allocator, 2, 1);
    defer canvas.deinit();
    canvas.clear(Color.black);
    const camera = @import("camera.zig").Camera2D{ .position = .{ .x = 1, .y = 0.5 } };
    const source = [_]Color{ Color.rgb(255, 0, 0), Color.rgb(0, 255, 0) };
    const image = Image{ .allocator = std.testing.allocator, .width = 2, .height = 1, .pixels = @constCast(&source) };
    map.drawImagesAt(CameraCanvas.init(&canvas, &camera), &.{image}, 0);
    try std.testing.expectEqual(Color.rgb(0, 64, 0), canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.rgb(64, 0, 0), canvas.get(1, 0).?);
}
