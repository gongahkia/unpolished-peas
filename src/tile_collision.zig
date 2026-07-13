const std = @import("std");
const collision = @import("collision.zig");
const Vec2 = @import("math.zig").Vec2;
const Rect = @import("math.zig").Rect;
const tilemap = @import("tilemap.zig");

pub const Slope = struct { a: Vec2, b: Vec2, normal: Vec2 };
pub const Shape = union(enum) { solid: Rect, one_way: Rect, slope: Slope };
pub const Hit = struct { normal: Vec2, fraction: f32, one_way: bool = false };

pub const TileCollider = struct {
    allocator: std.mem.Allocator,
    shapes: std.ArrayListUnmanaged(Shape) = .{},

    pub fn init(allocator: std.mem.Allocator) TileCollider {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TileCollider) void {
        self.shapes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addLayer(self: *TileCollider, map: *const tilemap.TileMap, layer_index: u32) !void {
        if (map.projection != .orthogonal) return error.UnsupportedCollisionProjection;
        if (layer_index >= map.layers.items.len) return error.InvalidCollisionLayer;
        const layer = &map.layers.items[layer_index];
        const offset = map.layerOffset(layer_index);
        const layer_one_way = propertiesEnabled(layer.properties, "one_way") or propertiesEnabled(layer.properties, "oneway");
        switch (layer.kind) {
            .tiles => for (layer.chunks.items) |chunk| for (chunk.tiles, 0..) |stack, index| {
                if (stack.items.items.len == 0) continue;
                const size: i32 = @intCast(map.chunk_size);
                const cell = tilemap.ChunkCoord{ .x = chunk.coord.x * size + @as(i32, @intCast(index % map.chunk_size)), .y = chunk.coord.y * size + @as(i32, @intCast(index / map.chunk_size)) };
                try self.appendRect(Rect.init(map.cellToWorld(cell).x + offset.x, map.cellToWorld(cell).y + offset.y, map.tile_size.x, map.tile_size.y), layer_one_way);
            },
            .int_grid => for (layer.chunks.items) |chunk| for (chunk.int_grid, 0..) |value, index| {
                if (value == 0) continue;
                const size: i32 = @intCast(map.chunk_size);
                const cell = tilemap.ChunkCoord{ .x = chunk.coord.x * size + @as(i32, @intCast(index % map.chunk_size)), .y = chunk.coord.y * size + @as(i32, @intCast(index / map.chunk_size)) };
                try self.appendRect(Rect.init(map.cellToWorld(cell).x + offset.x, map.cellToWorld(cell).y + offset.y, map.tile_size.x, map.tile_size.y), layer_one_way);
            },
            .objects => for (layer.objects.items) |object| try self.appendObject(object, offset, layer_one_way),
            .group => return error.InvalidCollisionLayer,
        }
    }

    pub fn overlaps(self: *const TileCollider, bounds: Rect) bool {
        for (self.shapes.items) |shape| switch (shape) {
            .solid => |rect| if (Rect.intersects(bounds, rect)) return true,
            .one_way => |rect| if (Rect.intersects(bounds, rect)) return true,
            .slope => |slope| if (Rect.intersects(bounds, slopeBounds(slope))) return true,
        };
        return false;
    }

    pub fn sweep(self: *const TileCollider, moving: Rect, delta: Vec2) ?Hit {
        var result: ?Hit = null;
        for (self.shapes.items) |shape| {
            const candidate = switch (shape) {
                .solid => |rect| rectHit(moving, delta, rect, false),
                .one_way => |rect| if (delta.y > 0 and moving.y + moving.h <= rect.y + 0.001) rectHit(moving, delta, rect, true) else null,
                .slope => null,
            } orelse continue;
            if (result == null or candidate.fraction < result.?.fraction) result = candidate;
        }
        return result;
    }

    pub fn overlapsSolid(self: *const TileCollider, bounds: Rect) bool {
        for (self.shapes.items) |shape| switch (shape) {
            .solid => |rect| if (Rect.intersects(bounds, rect)) return true,
            else => {},
        };
        return false;
    }

    fn appendRect(self: *TileCollider, bounds: Rect, one_way: bool) !void {
        try self.shapes.append(self.allocator, if (one_way) .{ .one_way = bounds } else .{ .solid = bounds });
    }

    fn appendObject(self: *TileCollider, object: tilemap.MapObject, offset: Vec2, layer_one_way: bool) !void {
        const one_way = layer_one_way or propertiesEnabled(object.properties, "one_way") or propertiesEnabled(object.properties, "oneway") or std.mem.eql(u8, object.class_name, "one_way") or std.mem.eql(u8, object.class_name, "oneway");
        const bounds = Rect.init(object.bounds.x + offset.x, object.bounds.y + offset.y, object.bounds.w, object.bounds.h);
        switch (object.shape) {
            .rectangle, .ellipse => try self.appendRect(bounds, one_way),
            .polygon => |points| try self.appendSlopes(points, object.bounds, offset),
            .polyline => |points| try self.appendSlopes(points, object.bounds, offset),
            .point => {},
        }
    }

    fn appendSlopes(self: *TileCollider, points: []const Vec2, object_bounds: Rect, offset: Vec2) !void {
        if (points.len < 2) return;
        for (points[0 .. points.len - 1], points[1..]) |a_raw, b_raw| try self.appendSlope(a_raw.add(.{ .x = object_bounds.x + offset.x, .y = object_bounds.y + offset.y }), b_raw.add(.{ .x = object_bounds.x + offset.x, .y = object_bounds.y + offset.y }));
        if (points.len > 2) try self.appendSlope(points[points.len - 1].add(.{ .x = object_bounds.x + offset.x, .y = object_bounds.y + offset.y }), points[0].add(.{ .x = object_bounds.x + offset.x, .y = object_bounds.y + offset.y }));
    }

    fn appendSlope(self: *TileCollider, first: Vec2, second: Vec2) !void {
        var a = first;
        var b = second;
        if (a.x > b.x) std.mem.swap(Vec2, &a, &b);
        const direction = b.sub(a);
        if (direction.x <= 0) return;
        const normal = Vec2.init(direction.y, -direction.x).normalized();
        if (normal.y >= -0.001) return;
        try self.shapes.append(self.allocator, .{ .slope = .{ .a = a, .b = b, .normal = normal } });
    }
};

pub const CharacterConfig = struct {
    bounds: Rect,
    max_step_height: f32 = 8,
    max_slope_degrees: f32 = 50,
    skin: f32 = 0.001,
};

pub const CharacterState = struct {
    bounds: Rect,
    grounded: bool,
    wall_left: bool,
    wall_right: bool,
    ceiling: bool,
};

pub const CharacterController = struct {
    bounds: Rect,
    max_step_height: f32,
    max_slope_degrees: f32,
    skin: f32,
    grounded: bool = false,
    wall_left: bool = false,
    wall_right: bool = false,
    ceiling: bool = false,

    pub fn init(config: CharacterConfig) !CharacterController {
        if (config.bounds.w <= 0 or config.bounds.h <= 0 or config.max_step_height < 0 or config.max_slope_degrees <= 0 or config.max_slope_degrees >= 90 or config.skin <= 0) return error.InvalidCharacterConfig;
        return .{ .bounds = config.bounds, .max_step_height = config.max_step_height, .max_slope_degrees = config.max_slope_degrees, .skin = config.skin };
    }

    pub fn move(self: *CharacterController, collider: *const TileCollider, delta: Vec2) CharacterState {
        const previous = self.bounds;
        const was_grounded = self.grounded;
        self.grounded = false;
        self.wall_left = false;
        self.wall_right = false;
        self.ceiling = false;
        var remaining = delta;
        var iterations: u8 = 0;
        while (iterations < 3 and remaining.lenSq() > 0.0000001) : (iterations += 1) {
            const hit = collider.sweep(self.bounds, remaining) orelse {
                self.bounds.x += remaining.x;
                self.bounds.y += remaining.y;
                break;
            };
            self.bounds.x += remaining.x * hit.fraction + hit.normal.x * self.skin;
            self.bounds.y += remaining.y * hit.fraction + hit.normal.y * self.skin;
            var rest = remaining.scale(1 - hit.fraction);
            if (hit.normal.x != 0) {
                if (was_grounded and self.tryStep(collider, rest.x)) {
                    rest.x = 0;
                } else if (hit.normal.x > 0) {
                    self.wall_left = true;
                    rest.x = 0;
                } else {
                    self.wall_right = true;
                    rest.x = 0;
                }
            } else if (hit.normal.y < 0) {
                self.grounded = true;
                rest.y = 0;
            } else {
                self.ceiling = true;
                rest.y = 0;
            }
            remaining = rest;
        }
        self.resolveSlope(collider, previous, was_grounded, delta);
        if (!self.grounded) self.grounded = self.onGround(collider);
        return .{ .bounds = self.bounds, .grounded = self.grounded, .wall_left = self.wall_left, .wall_right = self.wall_right, .ceiling = self.ceiling };
    }

    fn tryStep(self: *CharacterController, collider: *const TileCollider, horizontal: f32) bool {
        if (horizontal == 0 or self.max_step_height == 0) return false;
        var raised = self.bounds;
        raised.y -= self.max_step_height + self.skin;
        if (collider.overlapsSolid(raised)) return false;
        if (collider.sweep(raised, .{ .x = horizontal, .y = 0 })) |hit| if (hit.normal.x != 0) return false;
        raised.x += horizontal;
        const drop = collider.sweep(raised, .{ .x = 0, .y = self.max_step_height + self.skin * 2 }) orelse return false;
        if (drop.normal.y >= 0) return false;
        self.bounds = raised;
        self.bounds.y += (self.max_step_height + self.skin * 2) * drop.fraction - self.skin;
        self.grounded = true;
        return true;
    }

    fn resolveSlope(self: *CharacterController, collider: *const TileCollider, previous: Rect, was_grounded: bool, delta: Vec2) void {
        if (delta.y < 0) return;
        const minimum_normal_y = -std.math.cos(self.max_slope_degrees * std.math.pi / 180);
        const center_x = self.bounds.x + self.bounds.w / 2;
        for (collider.shapes.items) |shape| {
            const slope = switch (shape) {
                .slope => |value| value,
                else => continue,
            };
            if (slope.normal.y > minimum_normal_y) continue;
            if (center_x < slope.a.x or center_x > slope.b.x) continue;
            const fraction = (center_x - slope.a.x) / (slope.b.x - slope.a.x);
            const surface_y = slope.a.y + (slope.b.y - slope.a.y) * fraction;
            const bottom = self.bounds.y + self.bounds.h;
            const correction = surface_y - bottom;
            if (correction < -self.max_step_height or correction > self.max_step_height) continue;
            if (!was_grounded and previous.y + previous.h > surface_y + self.skin) continue;
            self.bounds.y += correction - self.skin;
            self.grounded = true;
            return;
        }
    }

    fn onGround(self: CharacterController, collider: *const TileCollider) bool {
        const hit = collider.sweep(self.bounds, .{ .x = 0, .y = self.skin * 2 }) orelse return false;
        return hit.normal.y < 0;
    }
};

fn propertiesEnabled(properties: []const tilemap.Property, name: []const u8) bool {
    for (properties) |property| {
        if (!std.mem.eql(u8, property.name, name)) continue;
        return switch (property.value) {
            .boolean => |value| value,
            .integer => |value| value != 0,
            .string => |value| std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
            else => false,
        };
    }
    return false;
}

fn rectHit(moving: Rect, delta: Vec2, target: Rect, one_way: bool) ?Hit {
    if (delta.y == 0 and (moving.y + moving.h <= target.y + 0.001 or moving.y >= target.y + target.h - 0.001)) return null;
    if (delta.x == 0 and (moving.x + moving.w <= target.x + 0.001 or moving.x >= target.x + target.w - 0.001)) return null;
    const hit = collision.sweepRect(moving, delta, target) orelse return null;
    return .{ .normal = hit.normal, .fraction = hit.fraction, .one_way = one_way };
}

fn slopeBounds(slope: Slope) Rect {
    return .{ .x = @min(slope.a.x, slope.b.x), .y = @min(slope.a.y, slope.b.y), .w = @abs(slope.b.x - slope.a.x), .h = @abs(slope.b.y - slope.a.y) };
}

test "platformer fixture resolves tile walls, steps, one way platforms, and slopes" {
    var map = try tilemap.TileMap.loadTiled(std.testing.allocator, "fixtures/platformer/collision.tmj");
    defer map.deinit();
    var collider = TileCollider.init(std.testing.allocator);
    defer collider.deinit();
    try collider.addLayer(&map, 0);
    try collider.addLayer(&map, 1);
    try std.testing.expectEqual(@as(usize, 15), collider.shapes.items.len);

    var fall = try CharacterController.init(.{ .bounds = Rect.init(36, 0, 12, 12), .max_step_height = 16 });
    const landed = fall.move(&collider, .{ .x = 0, .y = 100 });
    try std.testing.expect(landed.grounded);
    try std.testing.expect(landed.bounds.y + landed.bounds.h <= 48);

    var wall = try CharacterController.init(.{ .bounds = Rect.init(36, 36, 12, 12), .max_step_height = 16 });
    const blocked = wall.move(&collider, .{ .x = 100, .y = 0 });
    try std.testing.expect(blocked.wall_right);
    try std.testing.expect(blocked.bounds.x + blocked.bounds.w <= 64);

    var step = try CharacterController.init(.{ .bounds = Rect.init(0, 36, 12, 12), .max_step_height = 16 });
    step.grounded = true;
    const climbed = step.move(&collider, .{ .x = 20, .y = 0 });
    try std.testing.expect(climbed.grounded);
    try std.testing.expect(climbed.bounds.x > 16 and climbed.bounds.y + climbed.bounds.h <= 32);

    var platform = try CharacterController.init(.{ .bounds = Rect.init(96, 40, 12, 12), .max_step_height = 16 });
    _ = platform.move(&collider, .{ .x = 0, .y = -40 });
    const platform_landed = platform.move(&collider, .{ .x = 0, .y = 80 });
    try std.testing.expect(platform_landed.grounded);
    try std.testing.expect(platform_landed.bounds.y + platform_landed.bounds.h <= 32);

    var slope = try CharacterController.init(.{ .bounds = Rect.init(128, 36, 12, 12), .max_step_height = 16 });
    slope.grounded = true;
    const climbed_slope = slope.move(&collider, .{ .x = 16, .y = 0 });
    try std.testing.expect(climbed_slope.grounded);
    try std.testing.expect(climbed_slope.bounds.y < 36);
}

test "tile collider derives nonzero IntGrid cells" {
    var map = try tilemap.TileMap.init(std.testing.allocator, .{ .x = 16, .y = 16 }, 8);
    defer map.deinit();
    const layer = try map.addLayer("collision", .int_grid, null);
    try map.setIntGrid(layer, .{ .x = -1, .y = 2 }, 1);
    var collider = TileCollider.init(std.testing.allocator);
    defer collider.deinit();
    try collider.addLayer(&map, layer);
    try std.testing.expect(collider.overlaps(Rect.init(-16, 32, 16, 16)));
    try std.testing.expect(!collider.overlaps(Rect.init(0, 0, 8, 8)));
}
