const std = @import("std");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const render = @import("render.zig");

const fixture_bytes = @embedFile("fixtures/renderer/stable-core-v1.json");

pub const width: u32 = 64;
pub const height: u32 = 32;
pub const tolerance: u8 = 1;

const Fixture = struct {
    schema_version: u32,
    fixture_version: []const u8,
    font_fixture: []const u8,
    width: u32,
    height: u32,
    tolerance: Tolerance,
    assets: []Asset,
    operations: []Operation,
};

const Tolerance = struct {
    per_channel: u8,
};

const Asset = struct {
    id: []const u8,
    width: u32,
    height: u32,
    rgba: []u8,
};

const FixtureColor = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn value(self: FixtureColor) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

const Camera = struct {
    enabled: bool,
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 0,
    rotation: f32 = 0,
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
};

const Operation = struct {
    op: []const u8,
    color: ?FixtureColor = null,
    x: ?i32 = null,
    y: ?i32 = null,
    w: ?i32 = null,
    h: ?i32 = null,
    mode: ?u32 = null,
    asset: ?[]const u8 = null,
    value: ?[]const u8 = null,
    camera: ?Camera = null,
};

pub fn append(allocator: std.mem.Allocator, images: *std.ArrayList(Image), texts: *std.ArrayList([]u8), commands: *render.CommandBuffer) !void {
    var parsed = try std.json.parseFromSlice(Fixture, allocator, fixture_bytes, .{});
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.schema_version != 1 or !std.mem.eql(u8, fixture.fixture_version, "v1") or !std.mem.eql(u8, fixture.font_fixture, "debug-5x7-v1") or fixture.width != width or fixture.height != height or fixture.tolerance.per_channel != tolerance) return error.InvalidContractFixture;

    try appendAssets(allocator, fixture.assets, images);
    var camera: ?Camera = null;
    for (fixture.operations) |operation| {
        if (std.mem.eql(u8, operation.op, "clear")) {
            try commands.append(.{ .clear = try color(operation.color) });
        } else if (std.mem.eql(u8, operation.op, "rect")) {
            try appendRect(commands, camera, try integer(operation.x), try integer(operation.y), try positive(operation.w), try positive(operation.h), try color(operation.color));
        } else if (std.mem.eql(u8, operation.op, "image")) {
            if (camera != null) return error.InvalidContractFixture;
            try commands.append(.{ .image = .{ .image = try imageForAsset(fixture.assets, images, operation.asset orelse return error.InvalidContractFixture), .x = try integer(operation.x), .y = try integer(operation.y) } });
        } else if (std.mem.eql(u8, operation.op, "text")) {
            if (camera != null) return error.InvalidContractFixture;
            const value = try allocator.dupe(u8, operation.value orelse return error.InvalidContractFixture);
            errdefer allocator.free(value);
            try texts.append(allocator, value);
            try commands.append(.{ .text = .{ .value = value, .x = try integer(operation.x), .y = try integer(operation.y), .color = try color(operation.color) } });
        } else if (std.mem.eql(u8, operation.op, "push_clip")) {
            try commands.append(.{ .push_clip = .{ .x = try integer(operation.x), .y = try integer(operation.y), .w = try nonnegative(operation.w), .h = try nonnegative(operation.h) } });
        } else if (std.mem.eql(u8, operation.op, "pop_clip")) {
            try commands.append(.pop_clip);
        } else if (std.mem.eql(u8, operation.op, "push_blend")) {
            const mode = operation.mode orelse return error.InvalidContractFixture;
            try commands.append(.{ .push_blend = std.meta.intToEnum(render.BlendMode, mode) catch return error.InvalidContractFixture });
        } else if (std.mem.eql(u8, operation.op, "pop_blend")) {
            try commands.append(.pop_blend);
        } else if (std.mem.eql(u8, operation.op, "set_camera")) {
            const next = operation.camera orelse return error.InvalidContractFixture;
            if (next.enabled) try validateCamera(next);
            camera = if (next.enabled) next else null;
        } else return error.InvalidContractFixture;
    }
    if (camera != null) return error.UnbalancedContractFixture;
}

fn appendAssets(allocator: std.mem.Allocator, assets: []const Asset, images: *std.ArrayList(Image)) !void {
    if (images.items.len != 0) return error.InvalidContractFixture;
    try images.ensureUnusedCapacity(allocator, assets.len);
    for (assets, 0..) |asset, index| {
        const pixels_len = std.math.mul(usize, @as(usize, asset.width), @as(usize, asset.height)) catch return error.InvalidContractFixture;
        const rgba_len = std.math.mul(usize, pixels_len, 4) catch return error.InvalidContractFixture;
        if (asset.id.len == 0 or asset.width == 0 or asset.height == 0 or asset.rgba.len != rgba_len) return error.InvalidContractFixture;
        for (assets[0..index]) |prior| if (std.mem.eql(u8, prior.id, asset.id)) return error.InvalidContractFixture;
        const pixels = try allocator.alloc(Color, pixels_len);
        errdefer allocator.free(pixels);
        for (pixels, 0..) |*pixel, pixel_index| {
            const offset = pixel_index * 4;
            pixel.* = .{ .r = asset.rgba[offset], .g = asset.rgba[offset + 1], .b = asset.rgba[offset + 2], .a = asset.rgba[offset + 3] };
        }
        images.appendAssumeCapacity(.{ .allocator = allocator, .width = asset.width, .height = asset.height, .pixels = pixels });
    }
}

fn imageForAsset(assets: []const Asset, images: *std.ArrayList(Image), id: []const u8) !*const Image {
    for (assets, 0..) |asset, index| if (std.mem.eql(u8, asset.id, id)) return &images.items[index];
    return error.InvalidContractFixture;
}

fn appendRect(commands: *render.CommandBuffer, camera: ?Camera, x: i32, y: i32, w: i32, h: i32, value: Color) !void {
    if (camera) |transform| {
        const a = transformPoint(transform, x, y);
        const b = transformPoint(transform, x + w, y);
        const c = transformPoint(transform, x + w, y + h);
        const d = transformPoint(transform, x, y + h);
        try commands.append(.{ .triangle = .{ .a = a, .b = b, .c = c, .color = value } });
        try commands.append(.{ .triangle = .{ .a = a, .b = c, .c = d, .color = value } });
    } else try commands.append(.{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = value } });
}

fn transformPoint(camera: Camera, x: i32, y: i32) @import("math.zig").Vec2 {
    const local_x = @as(f32, @floatFromInt(x)) - camera.x;
    const local_y = @as(f32, @floatFromInt(y)) - camera.y;
    const cosine = @cos(camera.rotation);
    const sine = @sin(camera.rotation);
    return .{
        .x = camera.viewport_x + camera.viewport_w / 2 + (cosine * local_x + sine * local_y) * camera.zoom,
        .y = camera.viewport_y + camera.viewport_h / 2 + (-sine * local_x + cosine * local_y) * camera.zoom,
    };
}

fn validateCamera(camera: Camera) !void {
    if (!std.math.isFinite(camera.x) or !std.math.isFinite(camera.y) or !std.math.isFinite(camera.zoom) or !std.math.isFinite(camera.rotation) or !std.math.isFinite(camera.viewport_x) or !std.math.isFinite(camera.viewport_y) or !std.math.isFinite(camera.viewport_w) or !std.math.isFinite(camera.viewport_h) or camera.zoom <= 0 or camera.viewport_w <= 0 or camera.viewport_h <= 0) return error.InvalidContractFixture;
}

fn integer(value: ?i32) !i32 {
    return value orelse error.InvalidContractFixture;
}

fn positive(value: ?i32) !i32 {
    const result = try integer(value);
    if (result <= 0) return error.InvalidContractFixture;
    return result;
}

fn nonnegative(value: ?i32) !i32 {
    const result = try integer(value);
    if (result < 0) return error.InvalidContractFixture;
    return result;
}

fn color(value: ?FixtureColor) !Color {
    return (value orelse return error.InvalidContractFixture).value();
}

test "stable core renderer fixture expands to balanced commands" {
    var commands = render.CommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    var images = std.ArrayList(Image).empty;
    defer {
        for (images.items) |*image| image.deinit();
        images.deinit(std.testing.allocator);
    }
    var texts = std.ArrayList([]u8).empty;
    defer {
        for (texts.items) |text| std.testing.allocator.free(text);
        texts.deinit(std.testing.allocator);
    }
    try append(std.testing.allocator, &images, &texts, &commands);
    try std.testing.expectEqual(@as(usize, 27), commands.commands.items.len);
}
