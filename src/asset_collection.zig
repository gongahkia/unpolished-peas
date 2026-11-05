const std = @import("std");
const image_module = @import("image.zig");
const font_module = @import("font_asset.zig");
const atlas_module = @import("atlas.zig");

/// Optional game-owned collection of decoded embedded assets. Returned
/// pointers remain stable as the collection grows and borrow its lifetime.
/// Do not deinit them individually or copy a live collection into two owners.
/// Encoded bytes are borrowed only during each synchronous load. Audio and
/// native runtime-file loading retain their existing, separate ownership.
pub const AssetCollection = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayListUnmanaged(Resource) = .{},

    const Resource = union(enum) {
        image: *image_module.Image,
        font: *font_module.Font,
        atlas: *atlas_module.Atlas,
    };

    pub fn init(allocator: std.mem.Allocator) AssetCollection {
        return .{ .allocator = allocator };
    }

    /// Releases resources in reverse load order. All previously returned
    /// pointers become invalid. The empty collection may then be reused.
    pub fn deinit(self: *AssetCollection) void {
        var remaining = self.resources.items.len;
        while (remaining > 0) {
            remaining -= 1;
            switch (self.resources.items[remaining]) {
                inline else => |resource| {
                    resource.deinit();
                    self.allocator.destroy(resource);
                },
            }
        }
        self.resources.deinit(self.allocator);
        self.resources = .{};
    }

    pub fn image(self: *AssetCollection, bytes: []const u8, options: image_module.DecodeOptions) !*image_module.Image {
        return self.adopt(.image, try image_module.Image.decode(self.allocator, bytes, options));
    }

    pub fn font(self: *AssetCollection, bytes: []const u8, options: font_module.LoadOptions) !*font_module.Font {
        return self.adopt(.font, try font_module.Font.decodeTrueType(self.allocator, bytes, options));
    }

    /// Loads one owned sheet image and its copied frame/animation metadata.
    /// Frame handles and SpriteAnimationPlayer continue to use normal Atlas APIs.
    pub fn atlas(self: *AssetCollection, bytes: []const u8, frames: []const atlas_module.FrameSpec, options: atlas_module.Atlas.DecodeOptions) !*atlas_module.Atlas {
        return self.adopt(.atlas, try atlas_module.Atlas.decode(self.allocator, bytes, frames, options));
    }

    fn adopt(self: *AssetCollection, comptime tag: std.meta.Tag(Resource), value: std.meta.Child(std.meta.TagPayload(Resource, tag))) !*@TypeOf(value) {
        var owned = value;
        errdefer owned.deinit();
        try self.resources.ensureUnusedCapacity(self.allocator, 1);
        const pointer = try self.allocator.create(@TypeOf(value));
        pointer.* = owned;
        self.resources.appendAssumeCapacity(@unionInit(Resource, @tagName(tag), pointer));
        return pointer;
    }
};

const test_image = [_]u8{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x20, 0, 0, 255, 0, 255, 0 };
const test_frames = [_]atlas_module.FrameSpec{
    .{ .name = "red", .x = 0, .y = 0, .w = 1, .h = 1 },
    .{ .name = "green", .x = 1, .y = 0, .w = 1, .h = 1 },
};

test "collection pointers survive growth and failed loads preserve prior resources" {
    var collection = AssetCollection.init(std.testing.allocator);
    defer collection.deinit();
    const first = try collection.image(&test_image, .{});
    for (0..20) |_| _ = try collection.image(&test_image, .{});
    try std.testing.expectEqual(@import("color.zig").Color.rgb(255, 0, 0), first.pixels[0]);
    const sheet = try collection.atlas(&test_image, &test_frames, .{});
    try std.testing.expectEqual(@as(usize, 1), sheet.findFrame("green").?.index);
    const prior = collection.resources.items.len;
    try std.testing.expectError(error.InvalidImage, collection.image("", .{}));
    try std.testing.expectError(error.InvalidFontData, collection.font("", .{}));
    try std.testing.expectError(error.InvalidAtlas, collection.atlas(&test_image, &.{}, .{}));
    try std.testing.expectError(error.DuplicateAtlasFrame, collection.atlas(&test_image, &.{ test_frames[0], test_frames[0] }, .{}));
    try std.testing.expectError(error.UnknownAnimationFrame, collection.atlas(&test_image, &test_frames, .{
        .animations = &.{.{ .name = "bad", .frames = &.{.{ .frame = "absent" }} }},
    }));
    try std.testing.expectEqual(prior, collection.resources.items.len);
    try std.testing.expectEqual(@as(u32, 2), first.width);
    collection.deinit();
    try std.testing.expectEqual(@as(usize, 0), collection.resources.items.len);
    _ = try collection.image(&test_image, .{});
}

fn allocationFailureScenario(allocator: std.mem.Allocator) !void {
    var collection = AssetCollection.init(allocator);
    defer collection.deinit();
    _ = try collection.image(&test_image, .{});
    _ = try collection.atlas(&test_image, &test_frames, .{
        .animations = &.{.{ .name = "blink", .frames = &.{ .{ .frame = "red" }, .{ .frame = "green" } } }},
    });
}

test "collection rolls back every image atlas and registration allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureScenario, .{});
}
