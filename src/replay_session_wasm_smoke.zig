const std = @import("std");
const up = @import("unpolished-peas");

const Game = struct {
    score: u32 = 0,
    variation: u32 = 0,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        var bytes: [4]u8 = undefined;
        const stored = try (try ctx.requireSaveData()).read("score", &bytes);
        if (stored.len != 4) return error.InvalidScore;
        self.score = std.mem.readInt(u32, &bytes, .little);
        var rng = up.core.DeterministicRng.init(ctx.simulation_seed orelse return error.MissingSeed);
        self.variation = try rng.uintBelow(4);
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, _: f32) !void {
        if (ctx.input.wasPressed(.action)) self.score += 1;
        self.score += @intFromFloat(ctx.input.pointer.delta.x);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, self.score, .little);
        try (try ctx.requireSaveData()).write("score", &bytes);
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        (try ctx.requireCanvas()).clear(up.core.Color.rgb(@intCast(self.score), @intCast(self.variation), 0));
    }
};

var failure: []const u8 = "";

/// Exercise the actual optional developer APIs on the freestanding target,
/// where pointer width and available host services differ from native tests.
pub export fn replaySessionWasmSmoke() u64 {
    failure = "";
    return run(std.heap.wasm_allocator) catch |err| {
        failure = @errorName(err);
        return 0;
    };
}

pub export fn replayFailurePointer() usize {
    return @intFromPtr(failure.ptr);
}
pub export fn replayFailureLength() usize {
    return failure.len;
}

fn run(allocator: std.mem.Allocator) !u64 {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(allocator);
    defer saves.deinit();
    try saves.capability().write("score", &.{ 7, 0, 0, 0 });
    const identity = up.preview.developer.InputReplay.Environment.Identity{ .game = "smoke", .build = "1", .assets = "1" };
    var recorder = try up.preview.developer.InputReplayRecorder.initSession(allocator, 60, 42, .{
        .identity = identity,
        .save_data = saves.capability(),
        .save_keys = &.{"score"},
    });
    defer recorder.deinit();
    var input = up.input.Input{};
    input.set(.action, true);
    input.setPointerPosition(.{}, .{ .x = 2 }, null);
    try recorder.record(input);
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const bytes = try replay.encode(allocator);
    defer allocator.free(bytes);
    var parsed = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer parsed.deinit(allocator);
    var runner = try up.testSupport.HeadlessGameRunner(Game).initReplay(allocator, 2, 2, parsed, identity);
    defer runner.deinit();
    try runner.runReplay(parsed);
    if (runner.game.score != 10 or runner.game.variation != 2) return error.SessionDidNotReproduce;
    var original: [4]u8 = undefined;
    _ = try saves.capability().read("score", &original);
    if (std.mem.readInt(u32, &original, .little) != 7) return error.PlaybackChangedSourceSave;
    var hash = up.testSupport.StateHash{};
    hash.updatePortable(runner.game);
    return hash.finish();
}
