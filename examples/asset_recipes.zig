//! Small compiled recipes. All resources come from embedded bytes or portable
//! GameContext capabilities; none of these functions imports a platform host.
const std = @import("std");
const up = @import("unpolished-peas");

pub const frames = [_]up.assets.AtlasFrameSpec{
    .{ .name = "left", .x = 0, .y = 0, .w = 8, .h = 16 },
    .{ .name = "right", .x = 8, .y = 0, .w = 8, .h = 16 },
};
pub const steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 0 }, .ticks = 6 },
    .{ .frame = .{ .index = 1 }, .ticks = 6 },
};
pub const clip = up.graphics.SpriteAnimationClip{ .steps = &steps, .mode = .loop };

/// Load once in init. Audio retains its own sound until host teardown;
/// AssetCollection.deinit does not unload it.
pub fn loadEffect(ctx: *up.core.GameContext) ?up.core.Audio.SoundHandle {
    const audio = ctx.audio orelse return null;
    return audio.loadWav(@embedFile("assets/blip.wav")) catch null;
}

/// Call for a gameplay event. Browser autoplay/device failures are recoverable.
pub fn playEffect(ctx: *up.core.GameContext, effect: ?up.core.Audio.SoundHandle) void {
    const audio = ctx.audio orelse return;
    _ = audio.play(effect orelse return, .{ .volume = 0.25 }) catch {};
}

pub fn loadProgress(ctx: *up.core.GameContext) u32 {
    const saves = ctx.save_data orelse return 0;
    var bytes: [4]u8 = undefined;
    const stored = saves.read("recipe-progress", &bytes) catch return 0;
    if (stored.len != bytes.len) return 0;
    return std.mem.readInt(u32, &bytes, .little);
}

pub fn saveProgress(ctx: *up.core.GameContext, score: u32) void {
    const saves = ctx.save_data orelse return;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, score, .little);
    saves.write("recipe-progress", &bytes) catch {};
}

test "recipe: draw an embedded image" {
    var assets = up.assets.AssetCollection.init(std.testing.allocator);
    defer assets.deinit();
    const image = try assets.image(@embedFile("assets/ball.png"), .{});
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, 16, 16);
    defer canvas.deinit();
    canvas.clear(up.core.Color.transparent);
    canvas.drawImage(image.*, 0, 0);
    try std.testing.expectEqual(up.core.Color.rgb(255, 198, 74), canvas.get(8, 8).?);
    try std.testing.expectEqual(up.core.Color.transparent, canvas.get(0, 0).?);
}

test "recipe: draw an authored font" {
    var assets = up.assets.AssetCollection.init(std.testing.allocator);
    defer assets.deinit();
    const font = try assets.font(@embedFile("assets/fonts/Basic-Regular.ttf"), .{
        .pixel_height = 12,
        .atlas_width = 128,
        .atlas_height = 128,
        .first_codepoint = 32,
        .codepoint_count = 96,
    });
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, 64, 20);
    defer canvas.deinit();
    canvas.clear(up.core.Color.transparent);
    font.drawText(&canvas, "Peas 42", 1, 1, up.core.Color.white);
    // Same authored-font golden as the pre-collection native/Wasm decoder.
    try std.testing.expectEqual(@as(u64, 6_940_701_260_184_702_440), up.testSupport.canvasHash(canvas));
}

test "recipe: advance animation only in fixed update and draw an atlas frame" {
    var assets = up.assets.AssetCollection.init(std.testing.allocator);
    defer assets.deinit();
    const atlas = try assets.atlas(@embedFile("assets/ball.png"), &frames, .{});
    try clip.validateForAtlas(atlas);
    var player = try up.graphics.SpriteAnimationPlayer.init(&clip);
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, 8, 16);
    defer canvas.deinit();
    player.advance(6);
    canvas.clear(up.core.Color.transparent);
    canvas.drawAtlasFrame(atlas.*, player.currentFrame(), 0, 0, .{});
    try std.testing.expectEqual(@as(usize, 1), player.currentFrame().index);
    try std.testing.expectEqual(up.core.Color.rgb(255, 198, 74), canvas.get(0, 8).?);
    try std.testing.expectEqual(up.core.Color.transparent, canvas.get(7, 0).?);
}

test "recipe: host-owned sound survives collection cleanup and blocked output is recoverable" {
    var audio = try up.core.Audio.init(std.testing.allocator, .{});
    defer audio.deinit();
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.audio = &audio;
    const effect = loadEffect(&ctx);
    try std.testing.expect(effect != null);
    var assets = up.assets.AssetCollection.init(std.testing.allocator);
    _ = try assets.image(@embedFile("assets/ball.png"), .{});
    assets.deinit();
    audio.setAvailability(.ready);
    _ = try audio.play(effect.?, .{});
    audio.setAvailability(.blocked);
    playEffect(&ctx, effect);
    try std.testing.expectError(error.AudioUnavailable, audio.play(effect.?, .{}));
}

test "recipe: explicit progress bytes round trip and malformed saves stay playable" {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(std.testing.allocator);
    defer saves.deinit();
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.save_data = saves.capability();
    try std.testing.expectEqual(@as(u32, 0), loadProgress(&ctx));
    saveProgress(&ctx, 42);
    try std.testing.expectEqual(@as(u32, 42), loadProgress(&ctx));
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0 }, try saves.capability().read("recipe-progress", &bytes));
    try saves.capability().write("recipe-progress", "bad");
    try std.testing.expectEqual(@as(u32, 0), loadProgress(&ctx));
    ctx.save_data = null;
    saveProgress(&ctx, 7);
    try std.testing.expectEqual(@as(u32, 0), loadProgress(&ctx));
}
