const std = @import("std");
const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
const Color = @import("color.zig").Color;
const Rect = @import("math.zig").Rect;
const Vec2 = @import("math.zig").Vec2;

pub const native_format = "unpolished-peas-map";
pub const native_version: u32 = 1;
const binary_magic = "UPMB\x01";
const max_map_bytes = 64 * 1024 * 1024;

pub const Projection = enum { orthogonal, isometric };
pub const LayerKind = enum { tiles, int_grid, group };
pub const TileSourceKind = enum { grid_image, image_collection, atlas_frames };

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
    atlas_frames: [][]u8 = &.{},

    fn deinit(self: *TileSet, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        for (self.atlas_frames) |frame| allocator.free(frame);
        allocator.free(self.atlas_frames);
        self.* = undefined;
    }
};

pub const Chunk = struct {
    coord: ChunkCoord,
    tiles: []?Tile,
    int_grid: []i32,

    fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
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

    fn deinit(self: *TileMapLayer, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.chunks.items) |*chunk| chunk.deinit(allocator);
        self.chunks.deinit(allocator);
        self.* = undefined;
    }
};

pub const TileMapProject = struct {
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

pub const TileMap = struct {
    allocator: std.mem.Allocator,
    projection: Projection = .orthogonal,
    tile_size: Vec2,
    chunk_size: u32 = 32,
    editable: bool = true,
    tilesets: std.ArrayListUnmanaged(TileSet) = .{},
    layers: std.ArrayListUnmanaged(TileMapLayer) = .{},

    pub fn init(allocator: std.mem.Allocator, tile_size: Vec2, chunk_size: u32) !TileMap {
        if (tile_size.x <= 0 or tile_size.y <= 0 or !validChunkSize(chunk_size)) return error.InvalidMapConfig;
        return .{ .allocator = allocator, .tile_size = tile_size, .chunk_size = chunk_size };
    }

    pub fn deinit(self: *TileMap) void {
        for (self.tilesets.items) |*tileset| tileset.deinit(self.allocator);
        self.tilesets.deinit(self.allocator);
        for (self.layers.items) |*entry| entry.deinit(self.allocator);
        self.layers.deinit(self.allocator);
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

    pub fn setTile(self: *TileMap, layer_index: u32, cell: ChunkCoord, tile: ?Tile) !void {
        if (!self.editable) return error.ReadOnlyMap;
        const target = self.findLayer(layer_index) orelse return error.InvalidLayer;
        if (target.kind != .tiles) return error.InvalidLayerKind;
        if (tile) |value| if (value.tileset >= self.tilesets.items.len) return error.InvalidTileSet;
        const chunk_coord = chunkFor(cell, self.chunk_size);
        const chunk = try self.ensureChunk(target, chunk_coord);
        chunk.tiles[cellIndex(cell, self.chunk_size)] = tile;
    }

    pub fn tileAt(self: TileMap, layer_index: u32, cell: ChunkCoord) ?Tile {
        if (layer_index >= self.layers.items.len) return null;
        const target = &self.layers.items[layer_index];
        if (target.kind != .tiles) return null;
        const chunk = findChunk(target, chunkFor(cell, self.chunk_size)) orelse return null;
        return chunk.tiles[cellIndex(cell, self.chunk_size)];
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
            if (layer.kind != .tiles or !layer.visible) continue;
            for (layer.chunks.items) |chunk| {
                for (chunk.tiles, 0..) |tile, index| {
                    const value = tile orelse continue;
                    const size: i32 = @intCast(self.chunk_size);
                    const local_x: i32 = @intCast(index % self.chunk_size);
                    const local_y: i32 = @intCast(index / self.chunk_size);
                    const cell = ChunkCoord{ .x = chunk.coord.x * size + local_x, .y = chunk.coord.y * size + local_y };
                    const position = self.cellToWorld(cell).add(layer.offset);
                    const color = debugTileColor(value, @intCast(layer_index));
                    world.fillRect(Rect.init(position.x, position.y, self.tile_size.x, self.tile_size.y), color);
                }
            }
        }
    }

    pub fn loadNative(allocator: std.mem.Allocator, path: []const u8) !TileMap {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_map_bytes);
        defer allocator.free(bytes);
        return decodeNative(allocator, bytes);
    }

    pub fn loadTiled(allocator: std.mem.Allocator, path: []const u8) !TileMap {
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
        const ranges = try parseTiledTileSets(&result, try array(root.get("tilesets") orelse return error.InvalidTiledMap));
        defer allocator.free(ranges);
        try parseTiledLayers(&result, try array(root.get("layers") orelse return error.InvalidTiledMap), null, ranges);
        result.editable = false;
        return result;
    }

    pub fn loadLdtkProject(allocator: std.mem.Allocator, path: []const u8) !TileMapProject {
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
            const layer_instances = level.get("layerInstances") orelse return error.ExternalLdtkLevelsUnsupported;
            const layers = try array(layer_instances);
            var map = try init(allocator, .{ .x = 16, .y = 16 }, 32);
            errdefer map.deinit();
            try parseLdtkTileSets(&map, tile_sets);
            try parseLdtkLayers(&map, layers);
            map.editable = false;
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
        if (!self.editable) return error.ReadOnlyMap;
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(binary_magic);
        var buffer: [8192]u8 = undefined;
        var writer = file.writer(&buffer);
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

    fn ensureChunk(self: *TileMap, target: *TileMapLayer, coord: ChunkCoord) !*Chunk {
        if (findChunk(target, coord)) |chunk| return chunk;
        const count = try cellCount(self.chunk_size);
        const tiles = try self.allocator.alloc(?Tile, count);
        errdefer self.allocator.free(tiles);
        @memset(tiles, null);
        const int_grid = try self.allocator.alloc(i32, count);
        errdefer self.allocator.free(int_grid);
        @memset(int_grid, 0);
        try target.chunks.append(self.allocator, .{ .coord = coord, .tiles = tiles, .int_grid = int_grid });
        return &target.chunks.items[target.chunks.items.len - 1];
    }
};

const TiledTileSetRange = struct { first_gid: u32, tileset: u16 };

fn parseTiledTileSets(map: *TileMap, values: std.json.Array) ![]TiledTileSetRange {
    var ranges = try map.allocator.alloc(TiledTileSetRange, values.items.len);
    errdefer map.allocator.free(ranges);
    for (values.items, 0..) |value, i| {
        const entry = try object(value);
        if (entry.get("source") != null) return error.ExternalTiledTileSetsUnsupported;
        const first_gid = try u32Value(entry.get("firstgid") orelse return error.InvalidTiledMap);
        const image = entry.get("image") orelse blk: {
            const tile_defs = try array(entry.get("tiles") orelse return error.InvalidTiledMap);
            if (tile_defs.items.len == 0) return error.InvalidTiledMap;
            const first_tile = try object(tile_defs.items[0]);
            break :blk first_tile.get("image") orelse return error.InvalidTiledMap;
        };
        const is_collection = entry.get("image") == null;
        const name = if (entry.get("name")) |name_value| try string(name_value) else "tileset";
        ranges[i] = .{
            .first_gid = first_gid,
            .tileset = try map.addTileSet(name, if (is_collection) .image_collection else .grid_image, try string(image), .{
                .x = try f32Value(entry.get("tilewidth") orelse return error.InvalidTiledMap),
                .y = try f32Value(entry.get("tileheight") orelse return error.InvalidTiledMap),
            }),
        };
        var tileset = &map.tilesets.items[ranges[i].tileset];
        if (entry.get("margin")) |margin| tileset.margin = try u32Value(margin);
        if (entry.get("spacing")) |spacing| tileset.spacing = try u32Value(spacing);
    }
    std.mem.sort(TiledTileSetRange, ranges, {}, struct { fn less(_: void, a: TiledTileSetRange, b: TiledTileSetRange) bool { return a.first_gid < b.first_gid; } }.less);
    return ranges;
}

fn parseTiledLayers(map: *TileMap, values: std.json.Array, parent: ?u32, ranges: []const TiledTileSetRange) !void {
    for (values.items) |value| {
        const entry = try object(value);
        const type_name = try string(entry.get("type") orelse return error.InvalidTiledMap);
        if (std.mem.eql(u8, type_name, "objectgroup") or std.mem.eql(u8, type_name, "imagelayer")) return error.UnsupportedTiledFeature;
        if (std.mem.eql(u8, type_name, "group")) {
            const group = try map.addLayer(try string(entry.get("name") orelse return error.InvalidTiledMap), .group, parent);
            try parseTiledLayers(map, try array(entry.get("layers") orelse return error.InvalidTiledMap), group, ranges);
            continue;
        }
        if (!std.mem.eql(u8, type_name, "tilelayer")) return error.UnsupportedTiledFeature;
        const layer_index = try map.addLayer(try string(entry.get("name") orelse return error.InvalidTiledMap), .tiles, parent);
        var layer = &map.layers.items[layer_index];
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
        if (entry.get("chunks")) |chunks| {
            for ((try array(chunks)).items) |chunk_value| {
                const chunk = try object(chunk_value);
                try setTiledData(map, layer_index, .{ .x = try i32Value(chunk.get("x") orelse return error.InvalidTiledMap), .y = try i32Value(chunk.get("y") orelse return error.InvalidTiledMap) }, try u32Value(chunk.get("width") orelse return error.InvalidTiledMap), try u32Value(chunk.get("height") orelse return error.InvalidTiledMap), chunk.get("data") orelse return error.InvalidTiledMap, ranges);
            }
        } else {
            try setTiledData(map, layer_index, .{ .x = 0, .y = 0 }, try u32Value(entry.get("width") orelse return error.InvalidTiledMap), try u32Value(entry.get("height") orelse return error.InvalidTiledMap), entry.get("data") orelse return error.InvalidTiledMap, ranges);
        }
    }
}

fn setTiledData(map: *TileMap, layer_index: u32, origin: ChunkCoord, width: u32, height: u32, data: std.json.Value, ranges: []const TiledTileSetRange) !void {
    const entries = try array(data);
    const expected = std.math.mul(usize, width, height) catch return error.InvalidTiledMap;
    if (entries.items.len != expected) return error.InvalidTiledMap;
    map.editable = true;
    defer map.editable = false;
    for (entries.items, 0..) |gid_value, index| {
        const gid = try u32Value(gid_value);
        if (gid == 0) continue;
        const x: i32 = @intCast(index % width);
        const y: i32 = @intCast(index / width);
        try map.setTile(layer_index, .{ .x = origin.x + x, .y = origin.y + y }, tiledTile(gid, ranges));
    }
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

fn parseLdtkTileSets(map: *TileMap, values: std.json.Array) !void {
    for (values.items) |value| {
        const entry = try object(value);
        const path = entry.get("relPath") orelse continue;
        const index = try map.addTileSet(try string(entry.get("identifier") orelse return error.InvalidLdtkProject), .grid_image, try string(path), .{
            .x = try f32Value(entry.get("tileGridSize") orelse return error.InvalidLdtkProject),
            .y = try f32Value(entry.get("tileGridSize") orelse return error.InvalidLdtkProject),
        });
        map.tilesets.items[index].source_id = try u32Value(entry.get("uid") orelse return error.InvalidLdtkProject);
    }
}

fn parseLdtkLayers(map: *TileMap, values: std.json.Array) !void {
    var reverse_index = values.items.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const entry = try object(values.items[reverse_index]);
        const type_name = try string(entry.get("__type") orelse return error.InvalidLdtkProject);
        const kind: LayerKind = if (std.mem.eql(u8, type_name, "IntGrid")) .int_grid else if (std.mem.eql(u8, type_name, "Tiles") or std.mem.eql(u8, type_name, "AutoLayer")) .tiles else return error.UnsupportedLdtkFeature;
        const layer_index = try map.addLayer(try string(entry.get("__identifier") orelse return error.InvalidLdtkProject), kind, null);
        var layer = &map.layers.items[layer_index];
        layer.visible = try boolValue(entry.get("visible") orelse return error.InvalidLdtkProject);
        layer.opacity = try f32Value(entry.get("__opacity") orelse return error.InvalidLdtkProject);
        const grid_size = try i32Value(entry.get("__gridSize") orelse return error.InvalidLdtkProject);
        map.tile_size = .{ .x = @floatFromInt(grid_size), .y = @floatFromInt(grid_size) };
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
                try map.setTile(layer_index, .{ .x = @divFloor(try i32Value(point.items[0]), grid_size), .y = @divFloor(try i32Value(point.items[1]), grid_size) }, .{ .tileset = tileset, .id = source_id, .flags = .{ .flip_x = if (tile.get("f")) |flags| ((try u32Value(flags)) & 1) != 0 else false, .flip_y = if (tile.get("f")) |flags| ((try u32Value(flags)) & 2) != 0 else false } });
            }
        }
    }
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
                if (chunk_obj.get("tiles")) |tiles_value| try parseTiles(chunk.tiles, try array(tiles_value));
                if (chunk_obj.get("int_grid")) |grid_value| try parseIntGrid(chunk.int_grid, try array(grid_value));
            }
        }
    }
}

fn parseTiles(output: []?Tile, values: std.json.Array) !void {
    if (values.items.len != output.len) return error.InvalidChunkData;
    for (values.items, 0..) |value, i| {
        if (value == .null) continue;
        const item = try object(value);
        output[i] = .{
            .tileset = @intCast(try u32Value(item.get("tileset") orelse return error.InvalidMap)),
            .id = try u32Value(item.get("id") orelse return error.InvalidMap),
            .flags = if (item.get("flags")) |flags| @bitCast(@as(u8, @intCast(try u32Value(flags)))) else .{},
        };
    }
}

fn parseIntGrid(output: []i32, values: std.json.Array) !void {
    if (values.items.len != output.len) return error.InvalidChunkData;
    for (values.items, 0..) |value, i| output[i] = try i32Value(value);
}

fn writeNative(map: TileMap, json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("format"); try json.write(native_format);
    try json.objectField("version"); try json.write(native_version);
    try json.objectField("projection"); try json.write(@tagName(map.projection));
    try json.objectField("tile_width"); try json.write(map.tile_size.x);
    try json.objectField("tile_height"); try json.write(map.tile_size.y);
    try json.objectField("chunk_size"); try json.write(map.chunk_size);
    try json.objectField("tilesets"); try json.beginArray();
    for (map.tilesets.items) |tileset| {
        try json.beginObject();
        try json.objectField("name"); try json.write(tileset.name);
        try json.objectField("kind"); try json.write(@tagName(tileset.kind));
        try json.objectField("path"); try json.write(tileset.path);
        try json.objectField("tile_width"); try json.write(tileset.tile_size.x);
        try json.objectField("tile_height"); try json.write(tileset.tile_size.y);
        try json.objectField("margin"); try json.write(tileset.margin);
        try json.objectField("spacing"); try json.write(tileset.spacing);
        if (tileset.source_id) |source_id| { try json.objectField("source_id"); try json.write(source_id); }
        try json.objectField("atlas_frames"); try json.beginArray();
        for (tileset.atlas_frames) |frame| try json.write(frame);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("layers"); try json.beginArray();
    for (map.layers.items) |layer| {
        try json.beginObject();
        try json.objectField("name"); try json.write(layer.name);
        try json.objectField("kind"); try json.write(@tagName(layer.kind));
        if (layer.parent) |parent| { try json.objectField("parent"); try json.write(parent); }
        try json.objectField("visible"); try json.write(layer.visible);
        try json.objectField("opacity"); try json.write(layer.opacity);
        try json.objectField("chunks"); try json.beginArray();
        for (layer.chunks.items) |chunk| {
            try json.beginObject();
            try json.objectField("x"); try json.write(chunk.coord.x);
            try json.objectField("y"); try json.write(chunk.coord.y);
            try json.objectField("tiles"); try json.beginArray();
            for (chunk.tiles) |tile| if (tile) |value| {
                try json.beginObject();
                try json.objectField("tileset"); try json.write(value.tileset);
                try json.objectField("id"); try json.write(value.id);
                try json.objectField("flags"); try json.write(@as(u8, @bitCast(value.flags)));
                try json.endObject();
            } else try json.write(null);
            try json.endArray();
            try json.objectField("int_grid"); try json.write(chunk.int_grid);
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

fn object(value: std.json.Value) !std.json.ObjectMap { return switch (value) { .object => |item| item, else => error.InvalidMap }; }
fn array(value: std.json.Value) !std.json.Array { return switch (value) { .array => |item| item, else => error.InvalidMap }; }
fn string(value: std.json.Value) ![]const u8 { return switch (value) { .string => |item| item, else => error.InvalidMap }; }
fn boolValue(value: std.json.Value) !bool { return switch (value) { .bool => |item| item, else => error.InvalidMap }; }
fn i32Value(value: std.json.Value) !i32 { return std.math.cast(i32, try i64Value(value)) orelse error.InvalidMap; }
fn u32Value(value: std.json.Value) !u32 { return std.math.cast(u32, try i64Value(value)) orelse error.InvalidMap; }
fn i64Value(value: std.json.Value) !i64 { return switch (value) { .integer => |item| item, else => error.InvalidMap }; }
fn f32Value(value: std.json.Value) !f32 { return switch (value) { .integer => |item| @floatFromInt(item), .float => |item| @floatCast(item), else => error.InvalidMap }; }
fn projectionValue(value: std.json.Value) !Projection { return std.meta.stringToEnum(Projection, try string(value)) orelse error.UnsupportedProjection; }
fn layerKindValue(value: std.json.Value) !LayerKind { return std.meta.stringToEnum(LayerKind, try string(value)) orelse error.InvalidMap; }
fn sourceKindValue(value: std.json.Value) !TileSourceKind { return std.meta.stringToEnum(TileSourceKind, try string(value)) orelse error.InvalidMap; }

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
