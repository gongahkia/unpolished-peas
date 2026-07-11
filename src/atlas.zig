const std = @import("std");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;

const max_atlas_bytes = 8 * 1024 * 1024;
const default_frame_duration: f32 = 0.1;

pub const AtlasFrameHandle = struct {
    index: usize,
};

pub const AnimationHandle = struct {
    index: usize,
};

pub const Origin = enum {
    top_left,
    center,
};

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

pub const AnimationFrame = struct {
    frame: AtlasFrameHandle,
    duration: f32,
};

pub const Animation = struct {
    name: []u8,
    frames: []AnimationFrame,
};

pub const AnimationPlayer = struct {
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
        const anim = self.atlas.animation(self.animation);
        if (anim.frames.len == 0) return;
        self.elapsed += dt;
        while (self.elapsed >= anim.frames[self.frame_index].duration) {
            self.elapsed -= anim.frames[self.frame_index].duration;
            if (self.frame_index + 1 < anim.frames.len) {
                self.frame_index += 1;
            } else if (self.loop) {
                self.frame_index = 0;
            } else {
                self.playing = false;
                self.elapsed = 0;
                break;
            }
        }
    }

    pub fn frame(self: AnimationPlayer) AtlasFrameHandle {
        const anim = self.atlas.animation(self.animation);
        return anim.frames[self.frame_index].frame;
    }
};

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    image: Image,
    image_path: []u8,
    frames: []AtlasFrame,
    animations: []Animation,

    pub fn load(allocator: std.mem.Allocator, json_path: []const u8) !Atlas {
        const json_bytes = try std.fs.cwd().readFileAlloc(allocator, json_path, max_atlas_bytes);
        defer allocator.free(json_bytes);

        const image_rel = try imagePathFromJson(allocator, json_bytes);
        defer allocator.free(image_rel);
        const image_path = try resolveSiblingPath(allocator, json_path, image_rel);
        defer allocator.free(image_path);

        const image_bytes = try std.fs.cwd().readFileAlloc(allocator, image_path, 32 * 1024 * 1024);
        defer allocator.free(image_bytes);
        return decode(allocator, image_bytes, image_path, json_bytes);
    }

    pub fn decode(allocator: std.mem.Allocator, image_bytes: []const u8, image_path: []const u8, json_bytes: []const u8) !Atlas {
        var image = try Image.decodePng(allocator, image_bytes);
        errdefer image.deinit();
        const owned_path = try allocator.dupe(u8, image_path);
        errdefer allocator.free(owned_path);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
        defer parsed.deinit();

        var state = ParseState.init(allocator);
        defer state.deinitScratch();
        try state.parse(parsed.value);
        return .{
            .allocator = allocator,
            .image = image,
            .image_path = owned_path,
            .frames = try state.frames.toOwnedSlice(allocator),
            .animations = try state.animations.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Atlas) void {
        for (self.frames) |*slot| self.allocator.free(slot.name);
        for (self.animations) |*anim| {
            self.allocator.free(anim.name);
            self.allocator.free(anim.frames);
        }
        self.allocator.free(self.frames);
        self.allocator.free(self.animations);
        self.allocator.free(self.image_path);
        self.image.deinit();
        self.* = undefined;
    }

    pub fn findFrame(self: Atlas, name: []const u8) ?AtlasFrameHandle {
        for (self.frames, 0..) |slot, index| {
            if (std.mem.eql(u8, slot.name, name)) return .{ .index = index };
        }
        return null;
    }

    pub fn findAnimation(self: Atlas, name: []const u8) ?AnimationHandle {
        for (self.animations, 0..) |anim, index| {
            if (std.mem.eql(u8, anim.name, name)) return .{ .index = index };
        }
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

const ParseState = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(AtlasFrame) = .{},
    animations: std.ArrayListUnmanaged(Animation) = .{},

    fn init(allocator: std.mem.Allocator) ParseState {
        return .{ .allocator = allocator };
    }

    fn deinitScratch(self: *ParseState) void {
        for (self.frames.items) |*frame| self.allocator.free(frame.name);
        for (self.animations.items) |*anim| {
            self.allocator.free(anim.name);
            self.allocator.free(anim.frames);
        }
        self.frames.deinit(self.allocator);
        self.animations.deinit(self.allocator);
    }

    fn parse(self: *ParseState, root: std.json.Value) !void {
        const root_obj = try object(root);
        const frames_value = root_obj.get("frames") orelse return error.InvalidAtlasJson;
        switch (frames_value) {
            .object => |frames_obj| try self.parseFramesObject(frames_obj),
            .array => |frames_array| try self.parseFramesArray(frames_array.items),
            else => return error.InvalidAtlasJson,
        }
        if (self.frames.items.len == 0) return error.InvalidAtlasJson;
        if (root_obj.get("animations")) |animations| try self.parseAnimationsObject(try object(animations));
        if (root_obj.get("meta")) |meta_value| {
            const meta = object(meta_value) catch return;
            if (meta.get("frameTags")) |tags| try self.parseAsepriteTags(try array(tags));
        }
    }

    fn parseFramesObject(self: *ParseState, frames_obj: std.json.ObjectMap) !void {
        var it = frames_obj.iterator();
        while (it.next()) |entry| {
            const fallback_name = entry.key_ptr.*;
            try self.appendFrame(fallback_name, entry.value_ptr.*);
        }
    }

    fn parseFramesArray(self: *ParseState, items: []const std.json.Value) !void {
        for (items, 0..) |item, index| {
            const item_obj = try object(item);
            const fallback = if (item_obj.get("filename")) |name_value| try string(name_value) else try std.fmt.allocPrint(self.allocator, "frame{}", .{index});
            defer if (item_obj.get("filename") == null) self.allocator.free(fallback);
            try self.appendFrame(fallback, item);
        }
    }

    fn appendFrame(self: *ParseState, fallback_name: []const u8, value: std.json.Value) !void {
        const value_obj = try object(value);
        const name = if (value_obj.get("filename")) |name_value| try string(name_value) else fallback_name;
        const frame_obj = if (value_obj.get("frame")) |frame_value| try object(frame_value) else value_obj;
        const rect = try readRect(frame_obj);
        const source: SizeI = if (value_obj.get("sourceSize")) |source_value| try readSize(try object(source_value)) else .{ .w = rect.w, .h = rect.h };
        const sprite: RectI = if (value_obj.get("spriteSourceSize")) |sprite_value| try readRect(try object(sprite_value)) else .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
        const duration = frameDuration(value_obj);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.frames.append(self.allocator, .{
            .name = owned,
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
            .source_w = source.w,
            .source_h = source.h,
            .offset_x = sprite.x,
            .offset_y = sprite.y,
            .rotated = boolField(value_obj, "rotated") orelse false,
            .duration = duration,
        });
    }

    fn parseAnimationsObject(self: *ParseState, animations_obj: std.json.ObjectMap) !void {
        var it = animations_obj.iterator();
        while (it.next()) |entry| {
            const items = try array(entry.value_ptr.*);
            var frames = std.ArrayListUnmanaged(AnimationFrame){};
            errdefer frames.deinit(self.allocator);
            for (items.items) |item| {
                switch (item) {
                    .string => |name| try frames.append(self.allocator, .{ .frame = try self.requireFrame(name), .duration = self.frameDurationByName(name) }),
                    .object => |item_obj| {
                        const name = try string(item_obj.get("frame") orelse item_obj.get("name") orelse return error.InvalidAtlasJson);
                        try frames.append(self.allocator, .{ .frame = try self.requireFrame(name), .duration = secondsField(item_obj, "duration") orelse self.frameDurationByName(name) });
                    },
                    else => return error.InvalidAtlasJson,
                }
            }
            try self.appendAnimation(entry.key_ptr.*, try frames.toOwnedSlice(self.allocator));
        }
    }

    fn parseAsepriteTags(self: *ParseState, tags: std.json.Array) !void {
        for (tags.items) |tag_value| {
            const tag = try object(tag_value);
            const name = try string(tag.get("name") orelse return error.InvalidAtlasJson);
            const from = try usizeValue(tag.get("from") orelse return error.InvalidAtlasJson);
            const to = try usizeValue(tag.get("to") orelse return error.InvalidAtlasJson);
            if (from >= self.frames.items.len or to >= self.frames.items.len or from > to) return error.InvalidAtlasJson;
            const direction = if (tag.get("direction")) |value| try string(value) else "forward";
            var frames = std.ArrayListUnmanaged(AnimationFrame){};
            errdefer frames.deinit(self.allocator);
            if (std.mem.eql(u8, direction, "reverse")) {
                var i = to + 1;
                while (i > from) {
                    i -= 1;
                    try self.appendAnimFrame(&frames, i);
                }
            } else {
                var i = from;
                while (i <= to) : (i += 1) try self.appendAnimFrame(&frames, i);
                if (std.mem.eql(u8, direction, "pingpong") and to > from) {
                    var back = to;
                    while (back > from + 1) {
                        back -= 1;
                        try self.appendAnimFrame(&frames, back);
                    }
                }
            }
            try self.appendAnimation(name, try frames.toOwnedSlice(self.allocator));
        }
    }

    fn appendAnimFrame(self: *ParseState, frames: *std.ArrayListUnmanaged(AnimationFrame), index: usize) !void {
        try frames.append(self.allocator, .{ .frame = .{ .index = index }, .duration = self.frames.items[index].duration });
    }

    fn appendAnimation(self: *ParseState, name: []const u8, frames: []AnimationFrame) !void {
        if (frames.len == 0) return error.InvalidAtlasJson;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.animations.append(self.allocator, .{ .name = owned, .frames = frames });
    }

    fn requireFrame(self: ParseState, name: []const u8) !AtlasFrameHandle {
        for (self.frames.items, 0..) |frame, index| {
            if (std.mem.eql(u8, frame.name, name)) return .{ .index = index };
        }
        return error.UnknownAtlasFrame;
    }

    fn frameDurationByName(self: ParseState, name: []const u8) f32 {
        for (self.frames.items) |frame| {
            if (std.mem.eql(u8, frame.name, name)) return frame.duration;
        }
        return default_frame_duration;
    }
};

pub fn imagePathFromJson(allocator: std.mem.Allocator, json_bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (root.get("image")) |value| return allocator.dupe(u8, try string(value));
    if (root.get("meta")) |meta_value| {
        const meta = try object(meta_value);
        if (meta.get("image")) |value| return allocator.dupe(u8, try string(value));
    }
    return error.InvalidAtlasJson;
}

pub fn resolveSiblingPath(allocator: std.mem.Allocator, base_path: []const u8, child: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(child)) return allocator.dupe(u8, child);
    if (std.fs.path.dirname(base_path)) |dir| return std.fs.path.join(allocator, &.{ dir, child });
    return allocator.dupe(u8, child);
}

const RectI = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const SizeI = struct {
    w: i32,
    h: i32,
};

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => error.InvalidAtlasJson,
    };
}

fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |items| items,
        else => error.InvalidAtlasJson,
    };
}

fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidAtlasJson,
    };
}

fn readRect(obj: std.json.ObjectMap) !RectI {
    return .{
        .x = try intField(obj, "x"),
        .y = try intField(obj, "y"),
        .w = try intField(obj, "w"),
        .h = try intField(obj, "h"),
    };
}

fn readSize(obj: std.json.ObjectMap) !SizeI {
    return .{ .w = try intField(obj, "w"), .h = try intField(obj, "h") };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) !i32 {
    return try i32Value(obj.get(key) orelse return error.InvalidAtlasJson);
}

fn secondsField(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = obj.get(key) orelse return null;
    return f32Value(value) catch null;
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn frameDuration(obj: std.json.ObjectMap) f32 {
    if (obj.get("duration_ms")) |value| return (f32Value(value) catch 100) / 1000.0;
    if (obj.get("duration")) |value| return (f32Value(value) catch 100) / 1000.0;
    return default_frame_duration;
}

fn i32Value(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |i| std.math.cast(i32, i) orelse error.InvalidAtlasJson,
        .float => |f| @intFromFloat(f),
        .number_string => |s| try std.fmt.parseInt(i32, s, 10),
        else => error.InvalidAtlasJson,
    };
}

fn usizeValue(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |i| std.math.cast(usize, i) orelse error.InvalidAtlasJson,
        .float => |f| @intFromFloat(f),
        .number_string => |s| try std.fmt.parseInt(usize, s, 10),
        else => error.InvalidAtlasJson,
    };
}

fn f32Value(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .number_string => |s| try std.fmt.parseFloat(f32, s),
        else => error.InvalidAtlasJson,
    };
}

test "parses common atlas json variants" {
    const json =
        \\{"image":"atlas.png","frames":{"grass":{"x":0,"y":0,"w":8,"h":8},"water":{"frame":{"x":8,"y":0,"w":8,"h":8},"duration":120}},"animations":{"flow":["grass",{"frame":"water","duration":0.2}]}}
    ;
    const path = try imagePathFromJson(std.testing.allocator, json);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("atlas.png", path);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    var state = ParseState.init(std.testing.allocator);
    defer state.deinitScratch();
    try state.parse(parsed.value);
    try std.testing.expectEqual(@as(usize, 2), state.frames.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.animations.items.len);
    try std.testing.expectEqual(@as(f32, 0.12), state.frames.items[1].duration);
}

test "parses aseprite tags" {
    const json =
        \\{"meta":{"image":"atlas.png","frameTags":[{"name":"walk","from":0,"to":1,"direction":"pingpong"}]},"frames":[{"filename":"a","frame":{"x":0,"y":0,"w":4,"h":4},"duration":50},{"filename":"b","frame":{"x":4,"y":0,"w":4,"h":4},"duration":75}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    var state = ParseState.init(std.testing.allocator);
    defer state.deinitScratch();
    try state.parse(parsed.value);
    try std.testing.expectEqual(@as(usize, 2), state.frames.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.animations.items.len);
    try std.testing.expectEqual(@as(f32, 0.05), state.animations.items[0].frames[0].duration);
}

test "animation player advances tagged frames" {
    const pixels = try std.testing.allocator.dupe(Color, &.{ Color.white, Color.black });
    var atlas = Atlas{
        .allocator = std.testing.allocator,
        .image = .{ .allocator = std.testing.allocator, .width = 2, .height = 1, .pixels = pixels },
        .image_path = try std.testing.allocator.dupe(u8, "memory.png"),
        .frames = try std.testing.allocator.dupe(AtlasFrame, &.{
            .{ .name = try std.testing.allocator.dupe(u8, "a"), .x = 0, .y = 0, .w = 1, .h = 1, .source_w = 1, .source_h = 1, .offset_x = 0, .offset_y = 0 },
            .{ .name = try std.testing.allocator.dupe(u8, "b"), .x = 1, .y = 0, .w = 1, .h = 1, .source_w = 1, .source_h = 1, .offset_x = 0, .offset_y = 0 },
        }),
        .animations = try std.testing.allocator.dupe(Animation, &.{
            .{ .name = try std.testing.allocator.dupe(u8, "blink"), .frames = try std.testing.allocator.dupe(AnimationFrame, &.{ .{ .frame = .{ .index = 0 }, .duration = 0.1 }, .{ .frame = .{ .index = 1 }, .duration = 0.1 } }) },
        }),
    };
    defer atlas.deinit();
    var player = AnimationPlayer.init(&atlas, atlas.findAnimation("blink").?);
    player.update(0.11);
    try std.testing.expectEqual(@as(usize, 1), player.frame().index);
}
