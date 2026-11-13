const std = @import("std");
const up = @import("unpolished-peas");
const recipes = @import("asset_recipes.zig");

pub const width: u32 = 240;
pub const height: u32 = 120;
pub const default_seed: u64 = 42;

pub const Game = struct {
    pub const storage_id = "unpolished-peas.asset-workbench";
    assets: ?up.assets.AssetCollection = null,
    image: ?*const up.assets.Image = null,
    font: ?*const up.assets.Font = null,
    sheet: ?*const up.assets.Atlas = null,
    animation: ?up.graphics.SpriteAnimationPlayer = null,
    effect: ?up.core.Audio.SoundHandle = null,
    score: u32 = 0,
    x: f32 = 80,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        self.assets = up.assets.AssetCollection.init(try ctx.requireAllocator());
        errdefer self.deinit(ctx) catch {};
        const assets = &self.assets.?;
        self.image = try assets.image(@embedFile("assets/ball.png"), .{});
        self.font = try assets.font(@embedFile("assets/fonts/Basic-Regular.ttf"), .{
            .pixel_height = 12,
            .atlas_width = 128,
            .atlas_height = 128,
            .first_codepoint = 32,
            .codepoint_count = 96,
        });
        self.sheet = try assets.atlas(@embedFile("assets/ball.png"), &recipes.frames, .{});
        try recipes.clip.validateForAtlas(self.sheet.?);
        self.animation = try up.graphics.SpriteAnimationPlayer.init(&recipes.clip);
        self.effect = recipes.loadEffect(ctx);
        self.score = recipes.loadProgress(ctx);
    }

    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.assets) |*assets| assets.deinit();
        self.assets = null;
        self.image = null;
        self.font = null;
        self.sheet = null;
        self.animation = null;
        // `effect` borrows the Audio host; collection cleanup never unloads it.
        self.effect = null;
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, dt: f32) !void {
        self.animation.?.advance(1);
        if (ctx.input.isDown(.left)) self.x -= 48 * dt;
        if (ctx.input.isDown(.right)) self.x += 48 * dt;
        self.x = std.math.clamp(self.x, 60, 220);
        if (ctx.input.wasPressed(.action)) {
            self.score +|= 1;
            recipes.playEffect(ctx, self.effect);
            recipes.saveProgress(ctx, self.score);
        }
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.rgb(14, 18, 24));
        self.font.?.drawText(canvas, "Embedded assets, one owner", 8, 8, up.core.Color.white);
        canvas.drawImage(self.image.?.*, 20, 40);
        canvas.drawAtlasFrame(self.sheet.?.*, self.animation.?.currentFrame(), @intFromFloat(self.x), 34, .{ .scale = 2 });
        var buffer: [48]u8 = undefined;
        const label = try std.fmt.bufPrint(&buffer, "Saved score: {d}", .{self.score});
        self.font.?.drawText(canvas, label, 8, 78, up.core.Color.rgb(255, 198, 74));
        canvas.drawText("ARROWS move  SPACE sound + save", 8, 105, up.core.Color.white);
    }
};

test "asset example replays identical pixels and persists progress" {
    const allocator = std.testing.allocator;
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(allocator);
    defer saves.deinit();
    var first = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(allocator, width, height, 42, saves.capability());
    defer first.deinit();
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, 42);
    defer recorder.deinit();
    for (0..12) |tick| {
        var input = up.input.Input{};
        input.set(.right, true);
        input.set(.action, tick == 0 or tick == 6);
        try recorder.record(input);
        try first.step(input.snapshot(), 1.0 / 60.0);
    }
    try first.draw(0);
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    var second = try up.testSupport.HeadlessGameRunner(Game).initSeeded(allocator, width, height, 42);
    defer second.deinit();
    try second.runReplay(replay);
    try std.testing.expectEqual(@as(u32, 2), first.game.score);
    try std.testing.expectEqual(first.game.score, second.game.score);
    try std.testing.expectEqual(first.game.x, second.game.x);
    try std.testing.expectEqual(first.capture().image_hash, second.capture().image_hash);
    try up.testSupport.expectCanvasTraceEqual(first.capture().canvas_trace, second.capture().canvas_trace);
    const animation_before = first.game.animation.?.currentFrame();
    try first.draw(0.5);
    try std.testing.expectEqual(animation_before, first.game.animation.?.currentFrame());
    var restarted = try up.testSupport.HeadlessGameRunner(Game).initWithSaveData(allocator, width, height, saves.capability());
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u32, 2), restarted.game.score);
}

fn failedInitScenario(allocator: std.mem.Allocator) !void {
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = allocator;
    var game = Game{};
    try game.init(&ctx);
    defer game.deinit(&ctx) catch unreachable;
}

test "asset example cleans partial image font and atlas initialization at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failedInitScenario, .{});
}

test {
    _ = recipes;
}
