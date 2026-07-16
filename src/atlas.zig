const std = @import("std");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;

const default_frame_duration: f32 = 0.1;

pub const AtlasFrameHandle = struct { index: usize };
pub const AnimationHandle = struct { index: usize };
pub const Origin = enum { top_left, center };
pub const Sampling = enum { nearest, linear };

pub const DrawSpriteOptions = struct {
    origin: Origin = .top_left,
    scale: u32 = 1,
    flip_x: bool = false,
    flip_y: bool = false,
    tint: Color = Color.white,
    rotation: f32 = 0,
    sampling: Sampling = .nearest,
};

pub const AtlasFrame = struct {
    name: []u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    source_w: i32,
    source_h: i32,
    offset_x: i32,
    offset_y: i32,
    rotated: bool = false,
    duration: f32 = default_frame_duration,
};

pub const AnimationFrame = struct { frame: AtlasFrameHandle, duration: f32 };
pub const Animation = struct { name: []u8, frames: []AnimationFrame };

pub const FrameSpec = struct {
    name: []const u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    source_w: ?i32 = null,
    source_h: ?i32 = null,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    rotated: bool = false,
    duration: f32 = default_frame_duration,
};

pub const AnimationFrameSpec = struct { frame: []const u8, duration: f32 = default_frame_duration };
pub const AnimationSpec = struct { name: []const u8, frames: []const AnimationFrameSpec };

pub const AnimationPlayer = struct { // borrows its Atlas; the atlas must outlive the player.
    atlas: *const Atlas,
    animation: AnimationHandle,
    frame_index: usize = 0,
    elapsed: f32 = 0,
    playing: bool = true,
    loop: bool = true,

    pub fn init(atlas: *const Atlas, animation: AnimationHandle) AnimationPlayer {
        return .{ .atlas = atlas, .animation = animation };
    }

    pub fn play(self: *AnimationPlayer, animation: AnimationHandle) void {
        self.animation = animation;
        self.frame_index = 0;
        self.elapsed = 0;
        self.playing = true;
    }

    pub fn update(self: *AnimationPlayer, dt: f32) void {
        if (!self.playing or dt <= 0) return;
        const animation = self.atlas.animation(self.animation);
        if (animation.frames.len == 0) return;
        self.elapsed += dt;
        while (self.elapsed >= animation.frames[self.frame_index].duration) {
            self.elapsed -= animation.frames[self.frame_index].duration;
            if (self.frame_index + 1 < animation.frames.len) self.frame_index += 1 else if (self.loop) self.frame_index = 0 else {
                self.playing = false;
                self.elapsed = 0;
                break;
            }
        }
    }

    pub fn frame(self: AnimationPlayer) AtlasFrameHandle {
        return self.atlas.animation(self.animation).frames[self.frame_index].frame;
    }
};

pub const Atlas = struct { // owns its image, frame, and animation allocations; call deinit once after players are unused.
    allocator: std.mem.Allocator,
    image: Image,
    image_path: []u8,
    frames: []AtlasFrame,
    animations: []Animation,

    pub fn init(allocator: std.mem.Allocator, image: Image, image_path: []const u8, frame_specs: []const FrameSpec, animation_specs: []const AnimationSpec) !Atlas {
        if (frame_specs.len == 0) return error.InvalidAtlas;
        var atlas = Atlas{ .allocator = allocator, .image = image, .image_path = try allocator.dupe(u8, image_path), .frames = &.{}, .animations = &.{} };
        errdefer atlas.deinit();
        atlas.frames = try allocator.alloc(AtlasFrame, frame_specs.len);
        for (atlas.frames) |*entry| entry.* = .{ .name = &.{}, .x = 0, .y = 0, .w = 0, .h = 0, .source_w = 0, .source_h = 0, .offset_x = 0, .offset_y = 0 };
        for (frame_specs, 0..) |spec, index| {
            if (spec.name.len == 0 or spec.w <= 0 or spec.h <= 0 or spec.x < 0 or spec.y < 0 or !std.math.isFinite(spec.duration) or spec.duration <= 0) return error.InvalidAtlasFrame;
            const right = std.math.add(i32, spec.x, spec.w) catch return error.InvalidAtlasFrame;
            const bottom = std.math.add(i32, spec.y, spec.h) catch return error.InvalidAtlasFrame;
            if (right > image.width or bottom > image.height) return error.InvalidAtlasFrame;
            for (frame_specs[0..index]) |prior| if (std.mem.eql(u8, prior.name, spec.name)) return error.DuplicateAtlasFrame;
            atlas.frames[index] = .{ .name = try allocator.dupe(u8, spec.name), .x = spec.x, .y = spec.y, .w = spec.w, .h = spec.h, .source_w = spec.source_w orelse spec.w, .source_h = spec.source_h orelse spec.h, .offset_x = spec.offset_x, .offset_y = spec.offset_y, .rotated = spec.rotated, .duration = spec.duration };
        }
        atlas.animations = try allocator.alloc(Animation, animation_specs.len);
        for (atlas.animations) |*entry| entry.* = .{ .name = &.{}, .frames = &.{} };
        for (animation_specs, 0..) |spec, animation_index| {
            if (spec.name.len == 0 or spec.frames.len == 0) return error.InvalidAnimation;
            for (animation_specs[0..animation_index]) |prior| if (std.mem.eql(u8, prior.name, spec.name)) return error.DuplicateAnimation;
            const frames = try allocator.alloc(AnimationFrame, spec.frames.len);
            errdefer allocator.free(frames);
            for (spec.frames, 0..) |frame_spec, frame_index| {
                if (!std.math.isFinite(frame_spec.duration) or frame_spec.duration <= 0) return error.InvalidAnimation;
                const index = frameSpecIndex(frame_specs, frame_spec.frame) orelse return error.UnknownAnimationFrame;
                frames[frame_index] = .{ .frame = .{ .index = index }, .duration = frame_spec.duration };
            }
            atlas.animations[animation_index] = .{ .name = try allocator.dupe(u8, spec.name), .frames = frames };
        }
        return atlas;
    }

    pub fn deinit(self: *Atlas) void {
        for (self.frames) |*entry| if (entry.name.len != 0) self.allocator.free(entry.name);
        for (self.animations) |*entry| {
            if (entry.name.len != 0) self.allocator.free(entry.name);
            if (entry.frames.len != 0) self.allocator.free(entry.frames);
        }
        self.allocator.free(self.frames);
        self.allocator.free(self.animations);
        self.allocator.free(self.image_path);
        self.image.deinit();
        self.* = undefined;
    }

    pub fn findFrame(self: Atlas, name: []const u8) ?AtlasFrameHandle {
        for (self.frames, 0..) |entry, index| if (std.mem.eql(u8, entry.name, name)) return .{ .index = index };
        return null;
    }

    pub fn findAnimation(self: Atlas, name: []const u8) ?AnimationHandle {
        for (self.animations, 0..) |entry, index| if (std.mem.eql(u8, entry.name, name)) return .{ .index = index };
        return null;
    }

    pub fn frame(self: Atlas, handle: AtlasFrameHandle) AtlasFrame {
        std.debug.assert(handle.index < self.frames.len);
        return self.frames[handle.index];
    }

    pub fn animation(self: Atlas, handle: AnimationHandle) Animation {
        std.debug.assert(handle.index < self.animations.len);
        return self.animations[handle.index];
    }
};

fn frameSpecIndex(specs: []const FrameSpec, name: []const u8) ?usize {
    for (specs, 0..) |spec, index| if (std.mem.eql(u8, spec.name, name)) return index;
    return null;
}

pub fn resolveSiblingPath(allocator: std.mem.Allocator, base_path: []const u8, child: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(child)) return allocator.dupe(u8, child);
    if (std.fs.path.dirname(base_path)) |dir| return std.fs.path.join(allocator, &.{ dir, child });
    return allocator.dupe(u8, child);
}

test "programmatic atlas validates frames and animations" {
    const pixels = try std.testing.allocator.dupe(Color, &[_]Color{ Color.white, Color.white, Color.white, Color.white });
    var atlas = try Atlas.init(std.testing.allocator, .{ .allocator = std.testing.allocator, .width = 2, .height = 2, .pixels = pixels }, "memory", &.{ .{ .name = "a", .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .name = "b", .x = 1, .y = 0, .w = 1, .h = 1 } }, &.{.{ .name = "blink", .frames = &.{ .{ .frame = "a" }, .{ .frame = "b" } } }});
    defer atlas.deinit();
    var player = AnimationPlayer.init(&atlas, atlas.findAnimation("blink").?);
    player.update(0.11);
    try std.testing.expectEqual(@as(usize, 1), player.frame().index);
    try std.testing.expectError(error.UnknownAnimationFrame, Atlas.init(std.testing.allocator, try atlas.image.clone(std.testing.allocator), "memory", &.{.{ .name = "only", .x = 0, .y = 0, .w = 1, .h = 1 }}, &.{.{ .name = "bad", .frames = &.{.{ .frame = "missing" }} }}));
}
