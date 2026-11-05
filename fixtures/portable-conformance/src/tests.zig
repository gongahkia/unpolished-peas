const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const scenario = @import("scenario.zig");
const Runner = up.testSupport.HeadlessGameRunner(game.Game);
const identity = up.preview.developer.InputReplay.Environment.Identity{ .game = "portable-conformance", .build = "1", .assets = "fixture-1" };

test "downstream game captures initial saves before init and round trips a full UPR5 session" {
    const allocator = std.testing.allocator;
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(allocator);
    defer saves.deinit();
    var initial = game.Game{ .score = 7 };
    @memcpy(initial.name[0..5], "Start");
    initial.name_len = 5;
    const initial_bytes = initial.progress();
    try saves.capability().write("progress", &initial_bytes);
    var recorder = try up.preview.developer.InputReplayRecorder.initSession(allocator, 60, game.default_seed, .{
        .identity = identity,
        .save_data = saves.capability(),
        .save_keys = &.{"progress"},
    });
    defer recorder.deinit();
    const live = try Runner.initSeededWithSaveData(allocator, game.width, game.height, game.default_seed, saves.capability());
    defer live.deinit();
    for (0..scenario.ticks) |tick| {
        const input = try scenario.input(tick);
        try recorder.record(input);
        try live.step(input.snapshot(), 1.0 / 60.0);
    }
    try live.draw(0);
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const bytes = try replay.encode(allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("UPR5", bytes[0..4]);
    var parsed = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &initial_bytes, parsed.environment.?.saves[0].bytes.?);
    const reproduced = try Runner.initReplay(allocator, game.width, game.height, parsed, identity);
    defer reproduced.deinit();
    try std.testing.expectEqual(@as(u32, 7), reproduced.game.score);
    try reproduced.runReplay(parsed);
    try std.testing.expectEqual(@as(u32, 11), live.game.score);
    try std.testing.expectEqual(@as(u32, 1), live.game.one);
    try std.testing.expectEqual(@as(u32, 1), live.game.two);
    try std.testing.expectEqual(@as(i32, 119), live.game.x);
    try std.testing.expect(live.game.rebound);
    try std.testing.expectEqualStrings("StartZoë你好", live.game.name[0..live.game.name_len]);
    try std.testing.expectEqual(@as(usize, 0), live.game.preedit_len);
    try std.testing.expectEqual(@as(u32, 1), live.game.sound_requests);
    try std.testing.expectEqualSlices(u8, &live.game.progress(), &reproduced.game.progress());
    try std.testing.expectEqual(live.capture().image_hash, reproduced.capture().image_hash);
    try up.testSupport.expectCanvasTraceEqual(live.capture().canvas_trace, reproduced.capture().canvas_trace);
    const restarted = try Runner.initWithSaveData(allocator, game.width, game.height, saves.capability());
    defer restarted.deinit();
    try std.testing.expectEqualSlices(u8, &live.game.progress(), &restarted.game.progress());
}

test "failed downstream init cleans partial assets once without protocol double cleanup" {
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = std.testing.allocator;
    var state = game.Game{ .reject_init = true };
    var protocol = up.core.GameProtocol(game.Game).bind(&state);
    try std.testing.expectError(error.ConformanceInitRejected, protocol.init(&ctx));
    try std.testing.expect(state.assets == null and state.actions == null);
    try protocol.deinit(&ctx);
    try std.testing.expectEqual(@as(u32, 1), state.cleanup_calls);
}

fn failedAllocation(allocator: std.mem.Allocator) !void {
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = allocator;
    var state = game.Game{};
    try state.init(&ctx);
    defer state.deinit(&ctx) catch unreachable;
}
test "every downstream game allocation failure releases its prior resources" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failedAllocation, .{});
}

test "native wrapper forwards cleanup after success and partial failure" {
    const Desktop = @import("main.zig").Desktop;
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = std.testing.allocator;
    var normal = Desktop{};
    try normal.init(&ctx);
    try normal.deinit(&ctx);
    try std.testing.expectEqual(@as(u32, 1), normal.state.cleanup_calls);
    var failure = Desktop{ .state = .{ .reject_init = true } };
    try std.testing.expectError(error.ConformanceInitRejected, failure.init(&ctx));
    try std.testing.expectEqual(@as(u32, 1), failure.state.cleanup_calls);
}

const FailingStore = struct {
    inner: *up.core.SaveStore,
    capability: up.core.SaveStore = undefined,
    const operations = up.core.SaveStore.VTable{ .read_size = readSize, .read = read, .write = write, .delete = delete, .exists = exists };
    fn init(self: *FailingStore) void {
        self.capability = up.core.SaveStore.init(self, &operations);
    }
    fn readSize(_: *anyopaque, _: []const u8) up.core.SaveStore.Error!usize {
        return error.Unavailable;
    }
    fn read(_: *anyopaque, _: []const u8, _: []u8) up.core.SaveStore.Error!usize {
        return error.Unavailable;
    }
    fn write(_: *anyopaque, _: []const u8, _: []const u8) up.core.SaveStore.Error!void {
        return error.AccessDenied;
    }
    fn delete(_: *anyopaque, _: []const u8) up.core.SaveStore.Error!void {
        return error.AccessDenied;
    }
    fn exists(_: *anyopaque, _: []const u8) up.core.SaveStore.Error!bool {
        return error.Unavailable;
    }
};

test "unavailable saves and blocked audio keep the integrated game playable" {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(std.testing.allocator);
    defer saves.deinit();
    try saves.capability().write("progress", "old bytes remain");
    var rejected = FailingStore{ .inner = saves.capability() };
    rejected.init();
    const runner = try Runner.initWithSaveData(std.testing.allocator, game.width, game.height, &rejected.capability);
    defer runner.deinit();
    runner.audio.setAvailability(.blocked);
    for (0..scenario.ticks) |tick| {
        const input = try scenario.input(tick);
        try runner.step(input.snapshot(), 1.0 / 60.0);
    }
    try runner.draw(0);
    try std.testing.expectEqual(@as(u32, 4), runner.game.score);
    try std.testing.expectEqual(@as(u32, 1), runner.game.sound_requests);
    try std.testing.expect(!runner.audio.hasActivePlayback());
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("old bytes remain", try saves.capability().read("progress", &buffer));
    const effect = runner.game.effect.?;
    try runner.protocol.deinit(&runner.context);
    runner.audio.setAvailability(.ready);
    _ = try runner.audio.play(effect, .{}); // Audio outlives collection cleanup.
    try std.testing.expectEqual(@as(u32, 1), runner.game.cleanup_calls);
}

test "corrupt progress is rejected atomically before applying bindings or Unicode" {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(std.testing.allocator);
    defer saves.deinit();
    var initial = game.Game{ .score = 99, .rebound = true };
    var bytes = initial.progress();
    bytes[17] = 1;
    bytes[18] = 0xc0;
    try saves.capability().write("progress", &bytes);
    const runner = try Runner.initWithSaveData(std.testing.allocator, game.width, game.height, saves.capability());
    defer runner.deinit();
    try std.testing.expectEqual(@as(u32, 0), runner.game.score);
    try std.testing.expect(!runner.game.rebound);
    try std.testing.expectEqual(@as(usize, 0), runner.game.name_len);
}
