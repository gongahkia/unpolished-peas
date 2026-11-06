//! Portable, executed examples used verbatim by the API reference.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");

pub const Game = struct {
    x: i32 = 40,
    name: [64]u8 = .{0} ** 64,
    name_len: usize = 0,

    pub fn init(_: *Game, ctx: *up.core.GameContext) !void {
        try ctx.setTextInput(true);
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, _: f32) !void {
        if (ctx.input.isDown(.right)) self.x += 1;
        for (ctx.input.extended.eventSlice()) |event| {
            if (event.kind != .text_commit) continue;
            const text = ctx.input.extended.eventText(event);
            if (text.len > self.name.len - self.name_len) continue;
            @memcpy(self.name[self.name_len..][0..text.len], text);
            self.name_len += text.len;
        }
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.black);
        canvas.fillRect(self.x, 8, 4, 4, up.core.Color.white);
        canvas.drawText(self.name[0..self.name_len], 2, 2, up.core.Color.white);
    }

    pub fn deinit(_: *Game, ctx: *up.core.GameContext) !void {
        try ctx.setTextInput(false);
    }
};

pub fn offscreen(allocator: std.mem.Allocator) !u64 {
    var surface = try up.graphics.RenderSurface.init(allocator, 4, 4);
    defer surface.deinit();
    surface.canvas().clear(up.core.Color.transparent);
    surface.canvas().fillRect(1, 1, 2, 2, up.core.Color.rgb(20, 180, 90));
    var canvas = try up.graphics.Canvas.init(allocator, 16, 16);
    defer canvas.deinit();
    canvas.clear(up.core.Color.black);
    try canvas.drawSurface(&surface, .{ .x = 0, .y = 0, .width = 16, .height = 16 });
    if (!std.meta.eql(canvas.get(8, 8).?, up.core.Color.rgb(20, 180, 90))) return error.UnexpectedSurfacePixel;
    return up.testSupport.canvasHash(canvas);
}

pub fn rebind(allocator: std.mem.Allocator) !void {
    const definitions = [_]up.input.Action{
        .{ .name = "interact", .binding = .{ .physical_key = .q } },
    };
    var actions = try up.input.ActionMap.init(allocator, &definitions);
    defer actions.deinit();
    try actions.rebind("game", "interact", .{ .physical_key = .r });
    var input = up.input.Input{};
    input.setPhysical(.r, true, false); // A host observation, supplied by this test.
    actions.update(input);
    if (!actions.wasPressed("game", "interact")) return error.RebindDidNotTakeEffect;
}

pub fn loadMusic(ctx: *up.core.GameContext) !?up.core.Audio.MusicHandle {
    const audio = ctx.audio orelse return null;
    return try audio.loadMusic(@embedFile("assets/tone.ogg"), .{});
}

pub fn playMusic(ctx: *up.core.GameContext, handle: ?up.core.Audio.MusicHandle) void {
    const audio = ctx.audio orelse return;
    _ = audio.playMusic(handle orelse return, .{ .loop = true, .volume = 0.5 }) catch {};
}

pub fn replay(allocator: std.mem.Allocator) !u64 {
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, 42);
    defer recorder.deinit();
    var input = up.input.Input{};
    input.set(.right, true);
    input.setTextInputActive(true); // Test the observation after host activation.
    try input.commitText("Zoë");
    try recorder.record(input);
    var recorded = try recorder.finish();
    defer recorded.deinit(allocator);
    const bytes = try recorded.encode(allocator);
    defer allocator.free(bytes);
    var decoded = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer decoded.deinit(allocator);
    const runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(allocator, 64, 24, 42);
    defer runner.deinit();
    try runner.runReplay(decoded);
    if (runner.game.x != 41 or !std.mem.eql(u8, runner.game.name[0..runner.game.name_len], "Zoë")) return error.ReplayStateMismatch;
    return runner.capture().image_hash; // Capture borrows the runner.
}

var result_hash: u64 = 0;
pub fn verify(allocator: std.mem.Allocator) !u64 {
    try rebind(allocator);
    var audio = try up.core.Audio.init(allocator, .{});
    defer audio.deinit();
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.audio = &audio;
    const music = try loadMusic(&ctx);
    playMusic(&ctx, music);
    if (audio.musicState() != .playing) return error.MusicDidNotStart;
    var samples: [512]up.assets.AudioSample = undefined;
    try audio.mix(&samples);
    var nonzero = false;
    for (samples) |sample| {
        if (sample.left != 0 or sample.right != 0) nonzero = true;
    }
    if (!nonzero) return error.MusicDidNotDecode;
    audio.setAvailability(.blocked);
    playMusic(&ctx, music); // A blocked retry is recoverable.
    return try offscreen(allocator) ^ try replay(allocator);
}

test "API reference recipes run and release their owned resources" {
    const first = try verify(std.testing.allocator);
    try std.testing.expectEqual(first, try verify(std.testing.allocator));
}

pub export fn api_recipes_run() u32 {
    result_hash = verify(std.heap.page_allocator) catch return 1;
    return 0;
}
pub export fn api_recipes_hash() u64 {
    return result_hash;
}
pub fn main() !void {
    if (comptime builtin.os.tag == .freestanding) return;
    const value = try verify(std.heap.page_allocator);
    var bytes: [64]u8 = undefined;
    try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(&bytes, "{d}\n", .{value}));
}
