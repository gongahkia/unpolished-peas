const std = @import("std");
const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const Rect = @import("math.zig").Rect;
const Vec2 = @import("math.zig").Vec2;

pub const native_format = "unpolished-peas-map";
pub const native_version: u32 = 1;
const binary_magic = "UPMB\x01";
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
    id: u32,
    name: []u8,
    class_name: []u8,
    bounds: Rect,
    shape: ObjectShape,
    properties: []Property = &.{},

    fn deinit(self: *MapObject, allocator: std.mem.Allocator) void {
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

pub const TileMapLoadOptions = struct {
    overlay_path: ?[]const u8 = null,
};

pub const TileMapDependencyKind = enum { tileset, image, level, overlay };

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
    source_id: ?u32 = null,
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

pub const TileMapProject = struct { // owns parsed levels and maps allocated by load; call deinit once.
    allocator: std.mem.Allocator,
    levels: std.ArrayListUnmanaged(Level) = .{},

    pub const Level = struct {
        identifier: []u8,
        world_position: Vec2,
        map: TileMap,

        fn deinit(self: *Level, allocator: std.mem.Allocator) void {
            allocator.free(self.identifier);
            self.map.deinit();
            self.* = undefined;
        }
    };

    pub fn deinit(self: *TileMapProject) void {
        for (self.levels.items) |*level| level.deinit(self.allocator);
        self.levels.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn find(self: *TileMapProject, identifier: []const u8) ?*TileMap {
        for (self.levels.items) |*level| if (std.mem.eql(u8, level.identifier, identifier)) return &level.map;
        return null;
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

    pub fn loadNative(allocator: std.mem.Allocator, path: []const u8) !TileMap {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_map_bytes);
        defer allocator.free(bytes);
        var result = try decodeNative(allocator, bytes);
        errdefer result.deinit();
        for (result.tilesets.items) |tileset| {
            if (tileset.kind == .atlas_frames) continue;
            const resolved = try resolveSiblingPath(allocator, path, tileset.path);
            defer allocator.free(resolved);
            try result.addDependency(.image, resolved);
        }
        return result;
    }

    pub fn loadTiled(allocator: std.mem.Allocator, path: []const u8) !TileMap {
        return loadTiledWithOptions(allocator, path, .{});
    }

    pub fn loadTiledWithOptions(allocator: std.mem.Allocator, path: []const u8, options: TileMapLoadOptions) !TileMap {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_map_bytes);
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const root = try object(parsed.value);
        const orientation = try string(root.get("orientation") orelse return error.InvalidTiledMap);
        const projection: Projection = if (std.mem.eql(u8, orientation, "orthogonal")) .orthogonal else if (std.mem.eql(u8, orientation, "isometric")) .isometric else return error.UnsupportedProjection;
        if (root.get("infinite")) |infinite| _ = try boolValue(infinite);
        var result = try init(allocator, .{
            .x = try f32Value(root.get("tilewidth") orelse return error.InvalidTiledMap),
            .y = try f32Value(root.get("tileheight") orelse return error.InvalidTiledMap),
        }, 32);
        errdefer result.deinit();
        result.projection = projection;
        const ranges = try parseTiledTileSets(&result, try array(root.get("tilesets") orelse return error.InvalidTiledMap), path);
        defer allocator.free(ranges);
        try parseTiledLayers(&result, try array(root.get("layers") orelse return error.InvalidTiledMap), null, ranges);
        result.editable = false;
        if (options.overlay_path) |overlay_path| {
            try result.addDependency(.overlay, overlay_path);
            try result.applyOverlay(overlay_path);
        }
        return result;
    }

    pub fn loadLdtkProject(allocator: std.mem.Allocator, path: []const u8) !TileMapProject {
        return loadLdtkProjectWithOptions(allocator, path, .{});
    }

    pub fn loadLdtkProjectWithOptions(allocator: std.mem.Allocator, path: []const u8, options: TileMapLoadOptions) !TileMapProject {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_map_bytes);
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const root = try object(parsed.value);
        const definitions = try object(root.get("defs") orelse return error.InvalidLdtkProject);
        const tile_sets = try array(definitions.get("tilesets") orelse return error.InvalidLdtkProject);
        const levels = try array(root.get("levels") orelse return error.InvalidLdtkProject);
        var project = TileMapProject{ .allocator = allocator };
        errdefer project.deinit();
        for (levels.items) |level_json| {
            const level = try object(level_json);
            var map = try init(allocator, .{ .x = 16, .y = 16 }, 32);
            errdefer map.deinit();
            try parseLdtkTileSets(&map, tile_sets, path);
            const layer_instances = level.get("layerInstances") orelse return error.InvalidLdtkProject;
            if (layer_instances == .null) {
                const external_path = try resolveSiblingPath(allocator, path, try string(level.get("externalRelPath") orelse return error.InvalidLdtkProject));
                defer allocator.free(external_path);
                try map.addDependency(.level, external_path);
                const external_bytes = try std.fs.cwd().readFileAlloc(allocator, external_path, max_map_bytes);
                defer allocator.free(external_bytes);
                var external_parsed = try std.json.parseFromSlice(std.json.Value, allocator, external_bytes, .{});
                defer external_parsed.deinit();
                const external_level = try object(external_parsed.value);
                try parseLdtkLayers(&map, try array(external_level.get("layerInstances") orelse return error.InvalidLdtkProject));
            } else {
                try parseLdtkLayers(&map, try array(layer_instances));
            }
            map.editable = false;
            if (options.overlay_path) |overlay_path| {
                try map.addDependency(.overlay, overlay_path);
                try map.applyOverlay(overlay_path);
            }
            try project.levels.append(allocator, .{
                .identifier = try allocator.dupe(u8, try string(level.get("identifier") orelse return error.InvalidLdtkProject)),
                .world_position = .{
                    .x = if (level.get("worldX")) |value| try f32Value(value) else 0,
                    .y = if (level.get("worldY")) |value| try f32Value(value) else 0,
                },
                .map = map,
            });
        }
        return project;
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

    pub fn decodeNative(allocator: std.mem.Allocator, bytes: []const u8) !TileMap {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const root = try object(parsed.value);
        if (!std.mem.eql(u8, try string(root.get("format") orelse return error.InvalidMap), native_format)) return error.InvalidMapFormat;
        if (try u32Value(root.get("version") orelse return error.InvalidMap) != native_version) return error.UnsupportedMapVersion;
        const map = try init(allocator, .{
            .x = try f32Value(root.get("tile_width") orelse return error.InvalidMap),
            .y = try f32Value(root.get("tile_height") orelse return error.InvalidMap),
        }, try u32Value(root.get("chunk_size") orelse return error.InvalidMap));
        var result = map;
        errdefer result.deinit();
        result.projection = try projectionValue(root.get("projection") orelse return error.InvalidMap);
        if (root.get("tilesets")) |value| try parseTileSets(&result, try array(value));
        if (root.get("dependencies")) |value| try parseDependencies(&result, try array(value));
        try parseLayers(&result, try array(root.get("layers") orelse return error.InvalidMap));
        return result;
    }

    pub fn saveNative(self: TileMap, path: []const u8) !void {
        if (!self.editable) return error.ReadOnlyMap;
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buffer: [8192]u8 = undefined;
        var writer = file.writer(&buffer);
        var json = std.json.Stringify{ .writer = &writer.interface, .options = .{ .whitespace = .indent_2 } };
        try writeNative(self, &json);
        try writer.interface.flush();
    }

    pub fn writeBinary(self: TileMap, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buffer: [8192]u8 = undefined;
        var writer = file.writer(&buffer);
        try writer.interface.writeAll(binary_magic);
        var json = std.json.Stringify{ .writer = &writer.interface };
        try writeNative(self, &json);
        try writer.interface.flush();
    }

    pub fn loadBinary(allocator: std.mem.Allocator, path: []const u8) !TileMap {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_map_bytes);
        defer allocator.free(bytes);
        if (bytes.len < binary_magic.len or !std.mem.eql(u8, bytes[0..binary_magic.len], binary_magic)) return error.InvalidBinaryMap;
        var result = try decodeNative(allocator, bytes[binary_magic.len..]);
        result.editable = false;
        return result;
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

const TiledTileSetRange = struct { first_gid: u32, tileset: u16 };

fn parseTiledTileSets(map: *TileMap, values: std.json.Array, map_path: []const u8) ![]TiledTileSetRange {
    var ranges = try map.allocator.alloc(TiledTileSetRange, values.items.len);
    errdefer map.allocator.free(ranges);
    for (values.items, 0..) |value, i| {
        const entry = try object(value);
        const first_gid = try u32Value(entry.get("firstgid") orelse return error.InvalidTiledMap);
        const content = if (entry.get("source")) |source| {
            const parent = std.fs.path.dirname(map_path) orelse ".";
            const resolved = try std.fs.path.join(map.allocator, &.{ parent, try string(source) });
            defer map.allocator.free(resolved);
            try map.addDependency(.tileset, resolved);
            const bytes = try std.fs.cwd().readFileAlloc(map.allocator, resolved, max_map_bytes);
            defer map.allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, map.allocator, bytes, .{});
            defer parsed.deinit();
            const external = try object(parsed.value);
            ranges[i] = .{ .first_gid = first_gid, .tileset = try appendTiledTileSet(map, external, resolved) };
            continue;
        } else entry;
        ranges[i] = .{ .first_gid = first_gid, .tileset = try appendTiledTileSet(map, content, map_path) };
    }
    std.mem.sort(TiledTileSetRange, ranges, {}, struct {
        fn less(_: void, a: TiledTileSetRange, b: TiledTileSetRange) bool {
            return a.first_gid < b.first_gid;
        }
    }.less);
    return ranges;
}

fn resolveSiblingPath(allocator: std.mem.Allocator, path: []const u8, relative: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(path) orelse ".", relative });
}

fn appendTiledTileSet(map: *TileMap, entry: std.json.ObjectMap, source_path: []const u8) !u16 {
    const image = entry.get("image") orelse blk: {
        const tile_defs = try array(entry.get("tiles") orelse return error.InvalidTiledMap);
        if (tile_defs.items.len == 0) return error.InvalidTiledMap;
        const first_tile = try object(tile_defs.items[0]);
        break :blk first_tile.get("image") orelse return error.InvalidTiledMap;
    };
    const is_collection = entry.get("image") == null;
    const name = if (entry.get("name")) |name_value| try string(name_value) else "tileset";
    const resolved_image = try resolveSiblingPath(map.allocator, source_path, try string(image));
    defer map.allocator.free(resolved_image);
    const index = try map.addTileSet(name, if (is_collection) .image_collection else .grid_image, resolved_image, .{
        .x = try f32Value(entry.get("tilewidth") orelse return error.InvalidTiledMap),
        .y = try f32Value(entry.get("tileheight") orelse return error.InvalidTiledMap),
    });
    var tileset = &map.tilesets.items[index];
    try map.addDependency(.image, resolved_image);
    if (entry.get("margin")) |margin| tileset.margin = try u32Value(margin);
    if (entry.get("spacing")) |spacing| tileset.spacing = try u32Value(spacing);
    if (entry.get("tiles")) |tiles| {
        if (is_collection) {
            const definitions = try array(tiles);
            var max_id: u32 = 0;
            for (definitions.items) |tile_value| max_id = @max(max_id, try u32Value((try object(tile_value)).get("id") orelse return error.InvalidTiledMap));
            tileset.image_paths = try map.allocator.alloc(?[]u8, @as(usize, max_id) + 1);
            @memset(tileset.image_paths, null);
            for (definitions.items) |tile_value| {
                const tile = try object(tile_value);
                const id = try u32Value(tile.get("id") orelse return error.InvalidTiledMap);
                const tile_image = tile.get("image") orelse continue;
                const resolved = try resolveSiblingPath(map.allocator, source_path, try string(tile_image));
                errdefer map.allocator.free(resolved);
                tileset.image_paths[id] = resolved;
                try map.addDependency(.image, resolved);
            }
        }
        for ((try array(tiles)).items) |tile_value| {
            const tile = try object(tile_value);
            if (tile.get("animation")) |frames| try replaceAnimation(map.allocator, tileset, try u32Value(tile.get("id") orelse return error.InvalidTiledMap), try parseTiledAnimationFrames(map.allocator, try array(frames)));
        }
    }
    return index;
}

fn parseTiledAnimationFrames(allocator: std.mem.Allocator, values: std.json.Array) ![]TileAnimationFrame {
    const frames = try allocator.alloc(TileAnimationFrame, values.items.len);
    errdefer allocator.free(frames);
    for (values.items, 0..) |value, index| {
        const frame = try object(value);
        frames[index] = .{ .tile_id = try u32Value(frame.get("tileid") orelse return error.InvalidTiledMap), .duration = @as(f32, @floatFromInt(try u32Value(frame.get("duration") orelse return error.InvalidTiledMap))) / 1000 };
    }
    return frames;
}

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

fn parseTiledLayers(map: *TileMap, values: std.json.Array, parent: ?u32, ranges: []const TiledTileSetRange) !void {
    for (values.items) |value| {
        const entry = try object(value);
        const type_name = try string(entry.get("type") orelse return error.InvalidTiledMap);
        if (std.mem.eql(u8, type_name, "group")) {
            const group = try map.addLayer(try string(entry.get("name") orelse return error.InvalidTiledMap), .group, parent);
            try applyTiledLayerMetadata(map.allocator, &map.layers.items[group], entry);
            try parseTiledLayers(map, try array(entry.get("layers") orelse return error.InvalidTiledMap), group, ranges);
            continue;
        }
        if (std.mem.eql(u8, type_name, "objectgroup")) {
            const layer_index = try map.addLayer(try string(entry.get("name") orelse return error.InvalidTiledMap), .objects, parent);
            const layer = &map.layers.items[layer_index];
            try applyTiledLayerMetadata(map.allocator, layer, entry);
            for ((try array(entry.get("objects") orelse return error.InvalidTiledMap)).items) |object_value| {
                try layer.objects.append(map.allocator, try parseTiledObject(map.allocator, try object(object_value)));
            }
            continue;
        }
        if (std.mem.eql(u8, type_name, "imagelayer")) return error.UnsupportedTiledImageLayer;
        if (!std.mem.eql(u8, type_name, "tilelayer")) return error.UnsupportedTiledLayer;
        const layer_index = try map.addLayer(try string(entry.get("name") orelse return error.InvalidTiledMap), .tiles, parent);
        const layer = &map.layers.items[layer_index];
        try applyTiledLayerMetadata(map.allocator, layer, entry);
        if (entry.get("chunks")) |chunks| {
            for ((try array(chunks)).items) |chunk_value| {
                const chunk = try object(chunk_value);
                try setTiledData(map, layer_index, .{ .x = try i32Value(chunk.get("x") orelse return error.InvalidTiledMap), .y = try i32Value(chunk.get("y") orelse return error.InvalidTiledMap) }, try u32Value(chunk.get("width") orelse return error.InvalidTiledMap), try u32Value(chunk.get("height") orelse return error.InvalidTiledMap), chunk.get("data") orelse return error.InvalidTiledMap, if (entry.get("encoding")) |encoding| try string(encoding) else null, if (entry.get("compression")) |compression| try string(compression) else null, ranges);
            }
        } else {
            try setTiledData(map, layer_index, .{ .x = 0, .y = 0 }, try u32Value(entry.get("width") orelse return error.InvalidTiledMap), try u32Value(entry.get("height") orelse return error.InvalidTiledMap), entry.get("data") orelse return error.InvalidTiledMap, if (entry.get("encoding")) |encoding| try string(encoding) else null, if (entry.get("compression")) |compression| try string(compression) else null, ranges);
        }
    }
}

fn applyTiledLayerMetadata(allocator: std.mem.Allocator, layer: *TileMapLayer, entry: std.json.ObjectMap) !void {
    if (entry.get("visible")) |visible| layer.visible = try boolValue(visible);
    if (entry.get("opacity")) |opacity| layer.opacity = try f32Value(opacity);
    layer.offset = .{
        .x = if (entry.get("offsetx")) |offset| try f32Value(offset) else 0,
        .y = if (entry.get("offsety")) |offset| try f32Value(offset) else 0,
    };
    layer.parallax = .{
        .x = if (entry.get("parallaxx")) |factor| try f32Value(factor) else 1,
        .y = if (entry.get("parallaxy")) |factor| try f32Value(factor) else 1,
    };
    if (entry.get("properties")) |properties| layer.properties = try parseTiledProperties(allocator, try array(properties));
}

fn parseTiledObject(allocator: std.mem.Allocator, entry: std.json.ObjectMap) !MapObject {
    const polygon = entry.get("polygon");
    const polyline = entry.get("polyline");
    const shape: ObjectShape = if (polygon) |points|
        .{ .polygon = try parseTiledPoints(allocator, try array(points)) }
    else if (polyline) |points|
        .{ .polyline = try parseTiledPoints(allocator, try array(points)) }
    else if (entry.get("ellipse")) |ellipse| blk: {
        if (!try boolValue(ellipse)) return error.InvalidTiledMap;
        break :blk .ellipse;
    } else if (entry.get("point")) |point| blk: {
        if (!try boolValue(point)) return error.InvalidTiledMap;
        break :blk .point;
    } else .rectangle;
    var result = MapObject{
        .id = try u32Value(entry.get("id") orelse return error.InvalidTiledMap),
        .name = try allocator.dupe(u8, if (entry.get("name")) |name| try string(name) else ""),
        .class_name = try allocator.dupe(u8, if (entry.get("class")) |class| try string(class) else if (entry.get("type")) |class| try string(class) else ""),
        .bounds = .{ .x = try f32Value(entry.get("x") orelse return error.InvalidTiledMap), .y = try f32Value(entry.get("y") orelse return error.InvalidTiledMap), .w = if (entry.get("width")) |width| try f32Value(width) else 0, .h = if (entry.get("height")) |height| try f32Value(height) else 0 },
        .shape = shape,
    };
    errdefer result.deinit(allocator);
    if (entry.get("properties")) |properties| result.properties = try parseTiledProperties(allocator, try array(properties));
    return result;
}

fn parseTiledPoints(allocator: std.mem.Allocator, values: std.json.Array) ![]Vec2 {
    const points = try allocator.alloc(Vec2, values.items.len);
    errdefer allocator.free(points);
    for (values.items, 0..) |value, index| {
        const point = try object(value);
        points[index] = .{ .x = try f32Value(point.get("x") orelse return error.InvalidTiledMap), .y = try f32Value(point.get("y") orelse return error.InvalidTiledMap) };
    }
    return points;
}

fn parseTiledProperties(allocator: std.mem.Allocator, values: std.json.Array) ![]Property {
    const properties = try allocator.alloc(Property, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (properties[0..initialized]) |*property| property.deinit(allocator);
        allocator.free(properties);
    }
    for (values.items, 0..) |value, index| {
        properties[index] = try parseTiledProperty(allocator, try object(value));
        initialized += 1;
    }
    return properties;
}

fn parseTiledProperty(allocator: std.mem.Allocator, entry: std.json.ObjectMap) !Property {
    const property_type = if (entry.get("type")) |type_value| try string(type_value) else "string";
    const raw = entry.get("value") orelse return error.InvalidTiledMap;
    const name = try allocator.dupe(u8, try string(entry.get("name") orelse return error.InvalidTiledMap));
    errdefer allocator.free(name);
    const value: PropertyValue = if (std.mem.eql(u8, property_type, "string") or std.mem.eql(u8, property_type, "file")) .{ .string = try allocator.dupe(u8, try string(raw)) } else if (std.mem.eql(u8, property_type, "int") or std.mem.eql(u8, property_type, "object")) .{ .integer = try i64Value(raw) } else if (std.mem.eql(u8, property_type, "float")) .{ .float = @as(f64, try f32Value(raw)) } else if (std.mem.eql(u8, property_type, "bool")) .{ .boolean = try boolValue(raw) } else return error.UnsupportedTiledProperty;
    return .{ .name = name, .value = value };
}

fn setTiledData(map: *TileMap, layer_index: u32, origin: ChunkCoord, width: u32, height: u32, data: std.json.Value, encoding: ?[]const u8, compression: ?[]const u8, ranges: []const TiledTileSetRange) !void {
    const expected = std.math.mul(usize, width, height) catch return error.InvalidTiledMap;
    const entries = try decodeTiledData(map.allocator, data, encoding, compression, expected);
    defer map.allocator.free(entries);
    map.editable = true;
    defer map.editable = false;
    for (entries, 0..) |gid, index| {
        if (gid == 0) continue;
        const x: i32 = @intCast(index % width);
        const y: i32 = @intCast(index / width);
        try map.setTile(layer_index, .{ .x = origin.x + x, .y = origin.y + y }, tiledTile(gid, ranges));
    }
}

fn decodeTiledData(allocator: std.mem.Allocator, data: std.json.Value, encoding: ?[]const u8, compression: ?[]const u8, expected: usize) ![]u32 {
    const values = try allocator.alloc(u32, expected);
    errdefer allocator.free(values);
    switch (data) {
        .array => |items| {
            if (encoding != null or compression != null or items.items.len != expected) return error.InvalidTiledMap;
            for (items.items, 0..) |item, index| values[index] = try u32Value(item);
        },
        .string => |encoded| {
            if (!std.mem.eql(u8, encoding orelse return error.InvalidTiledMap, "base64")) return error.UnsupportedTiledEncoding;
            const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
            const max_size = try decoder.calcSizeUpperBound(encoded.len);
            var raw = try allocator.alloc(u8, max_size);
            defer allocator.free(raw);
            const raw_len = try decoder.decode(raw, encoded);
            const byte_len = std.math.mul(usize, expected, 4) catch return error.InvalidTiledMap;
            const bytes = try decodeTiledBytes(allocator, raw[0..raw_len], compression, byte_len);
            defer allocator.free(bytes);
            if (bytes.len != byte_len) return error.InvalidTiledMap;
            for (values, 0..) |*value, index| value.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
        },
        else => return error.InvalidTiledMap,
    }
    return values;
}

fn decodeTiledBytes(allocator: std.mem.Allocator, input: []const u8, compression: ?[]const u8, expected_len: usize) ![]u8 {
    const output = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(output);
    if (compression == null) {
        if (input.len != expected_len) return error.InvalidTiledMap;
        @memcpy(output, input);
        return output;
    }
    var reader: std.Io.Reader = .fixed(input);
    const name = compression.?;
    if (std.mem.eql(u8, name, "zlib") or std.mem.eql(u8, name, "gzip")) {
        var decompress: std.compress.flate.Decompress = .init(&reader, if (std.mem.eql(u8, name, "zlib")) .zlib else .gzip, &.{});
        try decompress.reader.readSliceAll(output);
    } else if (std.mem.eql(u8, name, "zstd")) {
        var decompress: std.compress.zstd.Decompress = .init(&reader, &.{}, .{});
        try decompress.reader.readSliceAll(output);
    } else return error.UnsupportedTiledCompression;
    return output;
}

fn tiledTile(gid: u32, ranges: []const TiledTileSetRange) Tile {
    const flip_x = (gid & 0x80000000) != 0;
    const flip_y = (gid & 0x40000000) != 0;
    const diagonal = (gid & 0x20000000) != 0;
    const raw = gid & 0x1fffffff;
    var selected = ranges[0];
    for (ranges) |range| {
        if (range.first_gid <= raw) selected = range;
    }
    return .{ .tileset = selected.tileset, .id = raw - selected.first_gid, .flags = .{ .flip_x = flip_x, .flip_y = flip_y, .diagonal = diagonal } };
}

fn parseLdtkTileSets(map: *TileMap, values: std.json.Array, project_path: []const u8) !void {
    for (values.items) |value| {
        const entry = try object(value);
        const path = entry.get("relPath") orelse continue;
        const resolved = try resolveSiblingPath(map.allocator, project_path, try string(path));
        defer map.allocator.free(resolved);
        const index = try map.addTileSet(try string(entry.get("identifier") orelse return error.InvalidLdtkProject), .grid_image, resolved, .{
            .x = try f32Value(entry.get("tileGridSize") orelse return error.InvalidLdtkProject),
            .y = try f32Value(entry.get("tileGridSize") orelse return error.InvalidLdtkProject),
        });
        try map.addDependency(.image, resolved);
        map.tilesets.items[index].source_id = try u32Value(entry.get("uid") orelse return error.InvalidLdtkProject);
    }
}

fn parseLdtkLayers(map: *TileMap, values: std.json.Array) !void {
    var reverse_index = values.items.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const entry = try object(values.items[reverse_index]);
        const type_name = try string(entry.get("__type") orelse return error.InvalidLdtkProject);
        const kind: LayerKind = if (std.mem.eql(u8, type_name, "IntGrid")) .int_grid else if (std.mem.eql(u8, type_name, "Tiles") or std.mem.eql(u8, type_name, "AutoLayer")) .tiles else if (std.mem.eql(u8, type_name, "Entities")) .objects else return error.UnsupportedLdtkFeature;
        const layer_index = try map.addLayer(try string(entry.get("__identifier") orelse return error.InvalidLdtkProject), kind, null);
        var layer = &map.layers.items[layer_index];
        layer.visible = try boolValue(entry.get("visible") orelse return error.InvalidLdtkProject);
        layer.opacity = try f32Value(entry.get("__opacity") orelse return error.InvalidLdtkProject);
        layer.offset = .{ .x = if (entry.get("__pxTotalOffsetX")) |value| @floatFromInt(try i32Value(value)) else 0, .y = if (entry.get("__pxTotalOffsetY")) |value| @floatFromInt(try i32Value(value)) else 0 };
        const grid_size = try i32Value(entry.get("__gridSize") orelse return error.InvalidLdtkProject);
        map.tile_size = .{ .x = @floatFromInt(grid_size), .y = @floatFromInt(grid_size) };
        if (kind == .objects) {
            for ((try array(entry.get("entityInstances") orelse return error.InvalidLdtkProject)).items) |entity| {
                try layer.objects.append(map.allocator, try parseLdtkEntity(map.allocator, try object(entity)));
            }
            continue;
        }
        map.editable = true;
        defer map.editable = false;
        if (kind == .int_grid) {
            const width = try u32Value(entry.get("__cWid") orelse return error.InvalidLdtkProject);
            for ((try array(entry.get("intGridCsv") orelse return error.InvalidLdtkProject)).items, 0..) |cell, index| {
                try map.setIntGrid(layer_index, .{ .x = @intCast(index % width), .y = @intCast(index / width) }, try i32Value(cell));
            }
        } else {
            const tiles_key = if (std.mem.eql(u8, type_name, "AutoLayer")) "autoLayerTiles" else "gridTiles";
            for ((try array(entry.get(tiles_key) orelse return error.InvalidLdtkProject)).items) |tile_value| {
                const tile = try object(tile_value);
                const point = try array(tile.get("px") orelse return error.InvalidLdtkProject);
                if (point.items.len != 2) return error.InvalidLdtkProject;
                const source_id = try u32Value(tile.get("t") orelse return error.InvalidLdtkProject);
                const source_uid = if (entry.get("__tilesetDefUid")) |uid| try u32Value(uid) else return error.InvalidLdtkProject;
                const tileset = findTileSetBySourceId(map, source_uid) orelse return error.InvalidLdtkProject;
                try map.pushTile(layer_index, .{ .x = @divFloor(try i32Value(point.items[0]), grid_size), .y = @divFloor(try i32Value(point.items[1]), grid_size) }, .{ .tileset = tileset, .id = source_id, .flags = .{ .flip_x = if (tile.get("f")) |flags| ((try u32Value(flags)) & 1) != 0 else false, .flip_y = if (tile.get("f")) |flags| ((try u32Value(flags)) & 2) != 0 else false }, .opacity = if (tile.get("a")) |opacity| try f32Value(opacity) else 1 });
            }
        }
    }
}

fn parseLdtkEntity(allocator: std.mem.Allocator, entry: std.json.ObjectMap) !MapObject {
    const px = try array(entry.get("px") orelse return error.InvalidLdtkProject);
    if (px.items.len != 2) return error.InvalidLdtkProject;
    var result = MapObject{
        .id = try u32Value(entry.get("defUid") orelse return error.InvalidLdtkProject),
        .name = try allocator.dupe(u8, try string(entry.get("__identifier") orelse return error.InvalidLdtkProject)),
        .class_name = try allocator.dupe(u8, try string(entry.get("__identifier") orelse return error.InvalidLdtkProject)),
        .bounds = .{ .x = @floatFromInt(try i32Value(px.items[0])), .y = @floatFromInt(try i32Value(px.items[1])), .w = @floatFromInt(try i32Value(entry.get("width") orelse return error.InvalidLdtkProject)), .h = @floatFromInt(try i32Value(entry.get("height") orelse return error.InvalidLdtkProject)) },
        .shape = .rectangle,
    };
    errdefer result.deinit(allocator);
    if (entry.get("fieldInstances")) |fields| result.properties = try parseLdtkFields(allocator, try array(fields));
    return result;
}

fn parseLdtkFields(allocator: std.mem.Allocator, values: std.json.Array) ![]Property {
    const properties = try allocator.alloc(Property, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (properties[0..initialized]) |*property| property.deinit(allocator);
        allocator.free(properties);
    }
    for (values.items, 0..) |value, index| {
        properties[index] = try parseLdtkField(allocator, try object(value));
        initialized += 1;
    }
    return properties;
}

fn parseLdtkField(allocator: std.mem.Allocator, field: std.json.ObjectMap) !Property {
    const field_type = try string(field.get("__type") orelse return error.InvalidLdtkProject);
    const raw = field.get("__value") orelse return error.InvalidLdtkProject;
    const name = try allocator.dupe(u8, try string(field.get("__identifier") orelse return error.InvalidLdtkProject));
    errdefer allocator.free(name);
    const property_value: PropertyValue = if (std.mem.eql(u8, field_type, "Int")) .{ .integer = try i64Value(raw) } else if (std.mem.eql(u8, field_type, "Float")) .{ .float = @as(f64, try f32Value(raw)) } else if (std.mem.eql(u8, field_type, "Bool")) .{ .boolean = try boolValue(raw) } else if (std.mem.eql(u8, field_type, "String") or std.mem.eql(u8, field_type, "Text") or std.mem.eql(u8, field_type, "FilePath")) .{ .string = try allocator.dupe(u8, try string(raw)) } else return error.UnsupportedLdtkField;
    return .{ .name = name, .value = property_value };
}

fn parseTileSets(map: *TileMap, values: std.json.Array) !void {
    for (values.items) |value| {
        const item = try object(value);
        const kind = try sourceKindValue(item.get("kind") orelse return error.InvalidMap);
        const index = try map.addTileSet(try string(item.get("name") orelse return error.InvalidMap), kind, try string(item.get("path") orelse return error.InvalidMap), .{
            .x = try f32Value(item.get("tile_width") orelse return error.InvalidMap),
            .y = try f32Value(item.get("tile_height") orelse return error.InvalidMap),
        });
        var tileset = &map.tilesets.items[index];
        if (item.get("margin")) |margin| tileset.margin = try u32Value(margin);
        if (item.get("spacing")) |spacing| tileset.spacing = try u32Value(spacing);
        if (item.get("source_id")) |source_id| tileset.source_id = try u32Value(source_id);
        if (item.get("atlas_frames")) |frames| {
            const items = try array(frames);
            const owned = try map.allocator.alloc([]u8, items.items.len);
            errdefer map.allocator.free(owned);
            for (items.items, 0..) |frame, i| owned[i] = try map.allocator.dupe(u8, try string(frame));
            tileset.atlas_frames = owned;
        }
    }
}

fn parseDependencies(map: *TileMap, values: std.json.Array) !void {
    for (values.items) |value| {
        const item = try object(value);
        const kind = std.meta.stringToEnum(TileMapDependencyKind, try string(item.get("kind") orelse return error.InvalidMap)) orelse return error.InvalidMap;
        try map.addDependency(kind, try string(item.get("path") orelse return error.InvalidMap));
    }
}

fn parseLayers(map: *TileMap, values: std.json.Array) !void {
    for (values.items) |value| {
        const item = try object(value);
        const layer_index = try map.addLayer(try string(item.get("name") orelse return error.InvalidMap), try layerKindValue(item.get("kind") orelse return error.InvalidMap), if (item.get("parent")) |parent| try u32Value(parent) else null);
        var layer = &map.layers.items[layer_index];
        if (item.get("visible")) |visible| layer.visible = try boolValue(visible);
        if (item.get("opacity")) |opacity| layer.opacity = try f32Value(opacity);
        if (item.get("chunks")) |chunk_value| {
            for ((try array(chunk_value)).items) |chunk_json| {
                const chunk_obj = try object(chunk_json);
                const chunk = try map.ensureChunk(layer, .{ .x = try i32Value(chunk_obj.get("x") orelse return error.InvalidMap), .y = try i32Value(chunk_obj.get("y") orelse return error.InvalidMap) });
                if (chunk_obj.get("tiles")) |tiles_value| try parseTiles(map.allocator, chunk.tiles, try array(tiles_value));
                if (chunk_obj.get("int_grid")) |grid_value| try parseIntGrid(chunk.int_grid, try array(grid_value));
            }
        }
    }
}

fn parseTiles(allocator: std.mem.Allocator, output: []TileStack, values: std.json.Array) !void {
    if (values.items.len != output.len) return error.InvalidChunkData;
    for (values.items, 0..) |value, i| {
        if (value == .null) continue;
        if (value == .array) {
            for ((try array(value)).items) |tile_value| try appendParsedTile(allocator, &output[i], tile_value);
        } else {
            try appendParsedTile(allocator, &output[i], value);
        }
    }
}

fn appendParsedTile(allocator: std.mem.Allocator, stack: *TileStack, tile_value: std.json.Value) !void {
    const item = try object(tile_value);
    try stack.items.append(allocator, .{
        .tileset = @intCast(try u32Value(item.get("tileset") orelse return error.InvalidMap)),
        .id = try u32Value(item.get("id") orelse return error.InvalidMap),
        .flags = if (item.get("flags")) |flags| @bitCast(@as(u8, @intCast(try u32Value(flags)))) else .{},
        .opacity = if (item.get("opacity")) |opacity| try f32Value(opacity) else 1,
    });
}

fn parseIntGrid(output: []i32, values: std.json.Array) !void {
    if (values.items.len != output.len) return error.InvalidChunkData;
    for (values.items, 0..) |value, i| output[i] = try i32Value(value);
}

fn writeNative(map: TileMap, json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("format");
    try json.write(native_format);
    try json.objectField("version");
    try json.write(native_version);
    try json.objectField("projection");
    try json.write(@tagName(map.projection));
    try json.objectField("tile_width");
    try json.write(map.tile_size.x);
    try json.objectField("tile_height");
    try json.write(map.tile_size.y);
    try json.objectField("chunk_size");
    try json.write(map.chunk_size);
    try json.objectField("tilesets");
    try json.beginArray();
    for (map.tilesets.items) |tileset| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(tileset.name);
        try json.objectField("kind");
        try json.write(@tagName(tileset.kind));
        try json.objectField("path");
        try json.write(tileset.path);
        try json.objectField("tile_width");
        try json.write(tileset.tile_size.x);
        try json.objectField("tile_height");
        try json.write(tileset.tile_size.y);
        try json.objectField("margin");
        try json.write(tileset.margin);
        try json.objectField("spacing");
        try json.write(tileset.spacing);
        if (tileset.source_id) |source_id| {
            try json.objectField("source_id");
            try json.write(source_id);
        }
        try json.objectField("atlas_frames");
        try json.beginArray();
        for (tileset.atlas_frames) |frame| try json.write(frame);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("dependencies");
    try json.beginArray();
    for (map.dependencies.items) |dependency| {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(dependency.kind));
        try json.objectField("path");
        try json.write(dependency.path);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("layers");
    try json.beginArray();
    for (map.layers.items) |layer| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(layer.name);
        try json.objectField("kind");
        try json.write(@tagName(layer.kind));
        if (layer.parent) |parent| {
            try json.objectField("parent");
            try json.write(parent);
        }
        try json.objectField("visible");
        try json.write(layer.visible);
        try json.objectField("opacity");
        try json.write(layer.opacity);
        try json.objectField("chunks");
        try json.beginArray();
        for (layer.chunks.items) |chunk| {
            try json.beginObject();
            try json.objectField("x");
            try json.write(chunk.coord.x);
            try json.objectField("y");
            try json.write(chunk.coord.y);
            try json.objectField("tiles");
            try json.beginArray();
            for (chunk.tiles) |stack| {
                if (stack.items.items.len == 0) {
                    try json.write(null);
                } else {
                    try json.beginArray();
                    for (stack.items.items) |value| {
                        try json.beginObject();
                        try json.objectField("tileset");
                        try json.write(value.tileset);
                        try json.objectField("id");
                        try json.write(value.id);
                        try json.objectField("flags");
                        try json.write(@as(u8, @bitCast(value.flags)));
                        try json.objectField("opacity");
                        try json.write(value.opacity);
                        try json.endObject();
                    }
                    try json.endArray();
                }
            }
            try json.endArray();
            try json.objectField("int_grid");
            try json.write(chunk.int_grid);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn findTileSetBySourceId(map: *const TileMap, source_id: u32) ?u16 {
    for (map.tilesets.items, 0..) |tileset, index| {
        if (tileset.source_id != null and tileset.source_id.? == source_id) return @intCast(index);
    }
    return null;
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
fn boolValue(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |item| item,
        else => error.InvalidMap,
    };
}
fn i32Value(value: std.json.Value) !i32 {
    return std.math.cast(i32, try i64Value(value)) orelse error.InvalidMap;
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
fn projectionValue(value: std.json.Value) !Projection {
    return std.meta.stringToEnum(Projection, try string(value)) orelse error.UnsupportedProjection;
}
fn layerKindValue(value: std.json.Value) !LayerKind {
    return std.meta.stringToEnum(LayerKind, try string(value)) orelse error.InvalidMap;
}
fn sourceKindValue(value: std.json.Value) !TileSourceKind {
    return std.meta.stringToEnum(TileSourceKind, try string(value)) orelse error.InvalidMap;
}

test "native tile map mutates signed chunks and round trips binary" {
    var map = try TileMap.init(std.testing.allocator, .{ .x = 8, .y = 8 }, 8);
    defer map.deinit();
    _ = try map.addTileSet("tiles", .grid_image, "tiles.png", .{ .x = 8, .y = 8 });
    const layer = try map.addLayer("ground", .tiles, null);
    try map.setTile(layer, .{ .x = -1, .y = -1 }, .{ .tileset = 0, .id = 2 });
    try std.testing.expectEqual(@as(u32, 2), map.tileAt(layer, .{ .x = -1, .y = -1 }).?.id);
    const isometric = TileMap{ .allocator = std.testing.allocator, .projection = .isometric, .tile_size = .{ .x = 8, .y = 8 } };
    try std.testing.expectEqual(Vec2.init(-4, -4), isometric.cellToWorld(.{ .x = -1, .y = 0 }));
}

test "native binary cache preserves tracked dependencies" {
    var map = try TileMap.init(std.testing.allocator, .{ .x = 8, .y = 8 }, 8);
    defer map.deinit();
    try map.addDependency(.tileset, "tiles.tsj");
    try map.addDependency(.image, "tiles.png");
    try map.addDependency(.overlay, "rules.json");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "cache.upmapb" });
    defer std.testing.allocator.free(path);
    try map.writeBinary(path);
    var cached = try TileMap.loadBinary(std.testing.allocator, path);
    defer cached.deinit();
    try std.testing.expectEqual(@as(usize, 3), cached.dependencies.items.len);
}

test "native tile map decodes strict minimal document" {
    const source =
        \\{"format":"unpolished-peas-map","version":1,"projection":"orthogonal","tile_width":8,"tile_height":8,"chunk_size":8,"tilesets":[],"layers":[]}
    ;
    var map = try TileMap.decodeNative(std.testing.allocator, source);
    defer map.deinit();
    try std.testing.expectEqual(@as(u32, 8), map.chunk_size);
    try std.testing.expectEqual(@as(usize, 0), map.layers.items.len);
}

test "Tiled object layers expose shapes and typed properties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\{"orientation":"orthogonal","tilewidth":16,"tileheight":16,"tilesets":[],"layers":[{"type":"objectgroup","name":"collision","offsetx":2,"offsety":3,"properties":[{"name":"enabled","type":"bool","value":true},{"name":"gravity","type":"float","value":9.5}],"objects":[{"id":7,"name":"wall","class":"solid","x":4,"y":5,"width":6,"height":7,"properties":[{"name":"damage","type":"int","value":3}]},{"id":8,"name":"path","x":0,"y":0,"polygon":[{"x":1,"y":2},{"x":3,"y":4}]}]}]}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "objects.tmj", .data = source });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "objects.tmj" });
    defer std.testing.allocator.free(path);

    var map = try TileMap.loadTiled(std.testing.allocator, path);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.layers.items.len);
    try std.testing.expectEqual(LayerKind.objects, map.layers.items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), map.layerProperties(0).len);
    try std.testing.expectEqual(@as(usize, 2), map.layerObjects(0).len);
    try std.testing.expectEqualStrings("wall", map.layerObjects(0)[0].name);
    try std.testing.expectEqual(@as(i64, 3), map.layerObjects(0)[0].properties[0].value.integer);
    try std.testing.expectEqual(@as(usize, 2), map.layerObjects(0)[1].shape.polygon.len);
}

test "Tiled tile rendering applies layer opacity and flip flags" {
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

test "Tiled approved subset preserves external embedded group and animation fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tileset_source =
        \\{"name":"external","tilewidth":8,"tileheight":8,"image":"external.png","tiles":[{"id":0,"animation":[{"tileid":0,"duration":100},{"tileid":1,"duration":200}]}]}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "tiles.tsj", .data = tileset_source });
    const map_source =
        \\{"orientation":"orthogonal","tilewidth":8,"tileheight":8,"tilesets":[{"firstgid":1,"source":"tiles.tsj"},{"firstgid":100,"name":"collection","tilewidth":8,"tileheight":8,"tiles":[{"id":0,"image":"single.png"}]}],"layers":[{"type":"group","name":"world","opacity":0.5,"offsetx":2,"offsety":3,"parallaxx":0.75,"parallaxy":0.5,"layers":[{"type":"tilelayer","name":"ground","width":1,"height":1,"data":[3758096385]}]}]}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "map.tmj", .data = map_source });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "map.tmj" });
    defer std.testing.allocator.free(path);

    var map = try TileMap.loadTiled(std.testing.allocator, path);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 2), map.tilesets.items.len);
    try std.testing.expectEqual(TileSourceKind.image_collection, map.tilesets.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), map.tilesets.items[0].animations.len);
    try std.testing.expectEqual(@as(?u32, 0), map.layers.items[1].parent);
    const state = map.layerState(1);
    try std.testing.expectEqual(@as(f32, 0.5), state.opacity);
    try std.testing.expectEqual(Vec2.init(2, 3), state.offset);
    const tile = map.tileAt(1, .{ .x = 0, .y = 0 }).?;
    try std.testing.expect(tile.flags.flip_x and tile.flags.flip_y and tile.flags.diagonal);
}

test "versioned finite embedded Tiled fixture preserves hierarchy flags and animation" {
    var map = try TileMap.loadTiled(std.testing.allocator, "fixtures/tiled/v1/finite-embedded.tmj");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.tilesets.items.len);
    try std.testing.expectEqual(@as(usize, 2), map.layers.items.len);
    try std.testing.expectEqual(@as(?u32, 0), map.layers.items[1].parent);
    try std.testing.expectEqual(@as(usize, 1), map.tilesets.items[0].animations.len);
    try std.testing.expect(map.tileAt(1, .{ .x = 0, .y = 0 }).?.flags.flip_x);
    const state = map.layerState(1);
    try std.testing.expectEqual(@as(f32, 0.5), state.opacity);
    try std.testing.expectEqual(Vec2.init(2, 3), state.offset);
}

test "versioned infinite external Tiled fixture preserves signed chunks and flags" {
    var map = try TileMap.loadTiled(std.testing.allocator, "fixtures/tiled/v1/infinite-external.tmj");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.tilesets.items.len);
    try std.testing.expectEqual(@as(usize, 1), map.tilesets.items[0].animations.len);
    const tile = map.tileAt(0, .{ .x = -1, .y = 2 }).?;
    try std.testing.expect(tile.flags.flip_x and tile.flags.flip_y and tile.flags.diagonal);
    try std.testing.expectEqual(@as(usize, 2), map.dependencies.items.len);
}

test "LDtk entities expose collision bounds metadata and IntGrid values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\{"defs":{"tilesets":[]},"levels":[{"identifier":"Level","worldX":0,"worldY":0,"layerInstances":[{"__type":"Entities","__identifier":"Collision","visible":true,"__opacity":1,"__gridSize":16,"entityInstances":[{"defUid":7,"__identifier":"Wall","px":[4,8],"width":16,"height":8,"fieldInstances":[{"__identifier":"damage","__type":"Int","__value":3},{"__identifier":"solid","__type":"Bool","__value":true}]}]},{"__type":"IntGrid","__identifier":"CollisionGrid","visible":true,"__opacity":0.5,"__gridSize":16,"__cWid":2,"intGridCsv":[0,1]}]}]}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "level.ldtk", .data = source });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "level.ldtk" });
    defer std.testing.allocator.free(path);
    var project = try TileMap.loadLdtkProject(std.testing.allocator, path);
    defer project.deinit();
    const map = &project.levels.items[0].map;
    try std.testing.expectEqual(@as(i32, 1), map.intGridAt(0, .{ .x = 1, .y = 0 }).?);
    const objects = map.layerObjects(1);
    try std.testing.expectEqual(@as(usize, 1), objects.len);
    try std.testing.expectEqual(Rect.init(4, 8, 16, 8), objects[0].bounds);
    try std.testing.expectEqual(@as(i64, 3), objects[0].properties[0].value.integer);
}

test "LDtk external level data is loaded through its tracked dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "external.json", .data = "{\"layerInstances\":[{\"__type\":\"IntGrid\",\"__identifier\":\"Grid\",\"visible\":true,\"__opacity\":1,\"__gridSize\":16,\"__cWid\":1,\"intGridCsv\":[7]}]}" });
    try tmp.dir.writeFile(.{ .sub_path = "project.ldtk", .data = "{\"defs\":{\"tilesets\":[]},\"levels\":[{\"identifier\":\"External\",\"worldX\":0,\"worldY\":0,\"layerInstances\":null,\"externalRelPath\":\"external.json\"}] }" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "project.ldtk" });
    defer std.testing.allocator.free(path);
    var project = try TileMap.loadLdtkProject(std.testing.allocator, path);
    defer project.deinit();
    try std.testing.expectEqual(@as(i32, 7), project.levels.items[0].map.intGridAt(0, .{ .x = 0, .y = 0 }).?);
    try std.testing.expectEqual(@as(usize, 1), project.levels.items[0].map.dependencies.items.len);
}
