// This file contains the platform-independent Seed Sprint game protocol.
const std = @import("std");
const up = @import("unpolished-peas");

pub const width: u32 = 160;
pub const height: u32 = 90;
pub const default_seed: u64 = 42;
/// The browser host uses this stable ID to namespace small save blobs. Keep it
/// stable alongside the desktop `organization` and `application` in `main.zig`.
pub const storage_id = "your-name.seed-sprint";

const player_start = up.core.Vec2{ .x = 80, .y = 45 };
const player_size: i32 = 8;
const pickup_radius: i32 = 4;
const movement_speed: f32 = 60;

/// Named actions keep the game code independent of keyboard and gamepad
/// details. The platform host normalizes Arrow keys, Space, Enter, D-pad,
/// left-stick, South, and Start into these public Peas input identities.
const actions = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "left", .binding = .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1 } } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "right", .binding = .{ .gamepad_axis = .{ .axis = .left_x } } },
    .{ .name = "up", .binding = .{ .key = .up } },
    .{ .name = "up", .binding = .{ .gamepad_axis = .{ .axis = .left_y, .sign = -1 } } },
    .{ .name = "down", .binding = .{ .key = .down } },
    .{ .name = "down", .binding = .{ .gamepad_axis = .{ .axis = .left_y } } },
    .{ .name = "dash", .binding = .{ .key = .action } },
    .{ .name = "dash", .binding = .{ .gamepad_button = .south } },
};

pub const Game = struct {
    rng: up.core.DeterministicRng = up.core.DeterministicRng.init(default_seed),
    player: up.core.Vec2 = player_start,
    pickup: up.core.Vec2 = .{},
    score: u32 = 0,
    best_score: u32 = 0,

    /// Initialization receives the seed selected by the host. A replay test
    /// supplies the same value through `HeadlessGameRunner.initSeeded`.
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        try self.reset(ctx.simulation_seed orelse default_seed);
        self.loadBestScore(ctx);
    }

    /// `update` runs at the host's fixed timestep. It never reads wall-clock
    /// time, platform events, or a renderer; it only consumes normalized input.
    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        if (ctx.input.wasPressed(.start)) {
            try self.reset(ctx.simulation_seed orelse default_seed);
            return;
        }

        const bindings = up.input.ActionMap{ .actions = &actions };
        const input = ctx.input.*;
        const dash_multiplier: f32 = if (bindings.value(input, "game", "dash") > 0) 1.8 else 1.0;
        const speed = movement_speed * dash_multiplier;
        const dx = bindings.value(input, "game", "right") - bindings.value(input, "game", "left");
        const dy = bindings.value(input, "game", "down") - bindings.value(input, "game", "up");
        self.player.x = std.math.clamp(self.player.x + dx * speed * elapsed_seconds, 4, @as(f32, @floatFromInt(width - player_size - 4)));
        self.player.y = std.math.clamp(self.player.y + dy * speed * elapsed_seconds, 14, @as(f32, @floatFromInt(height - player_size - 4)));

        if (self.collectsPickup()) {
            self.score += 1;
            if (self.score > self.best_score) {
                self.best_score = self.score;
                self.saveBestScore(ctx);
            }
            try self.spawnPickup();
        }
    }

    /// `draw` translates the state into ordinary logical Canvas requests. It
    /// owns no backend state and therefore works unchanged in headless tests.
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.rgb(12, 18, 28));
        canvas.fillRect(0, 10, @intCast(width), 1, up.core.Color.rgb(50, 70, 96));
        canvas.fillRect(0, 89, @intCast(width), 1, up.core.Color.rgb(50, 70, 96));
        canvas.fillCircle(@intFromFloat(self.pickup.x), @intFromFloat(self.pickup.y), pickup_radius, up.core.Color.rgb(255, 203, 79));
        canvas.fillRect(@intFromFloat(self.player.x), @intFromFloat(self.player.y), player_size, player_size, up.core.Color.rgb(92, 196, 255));

        var label_buffer: [24]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "SEEDS {d}  BEST {d}", .{ self.score, self.best_score });
        canvas.drawText(label, 4, 2, up.core.Color.rgb(232, 240, 248));
        canvas.drawText("ARROWS MOVE  SPACE DASH  ENTER RESTART", 4, 78, up.core.Color.rgb(159, 180, 201));
    }

    fn reset(self: *Game, seed: u64) !void {
        self.rng = up.core.DeterministicRng.init(seed);
        self.player = player_start;
        self.score = 0;
        try self.spawnPickup();
    }

    fn spawnPickup(self: *Game) !void {
        self.pickup = .{
            .x = 20 + @as(f32, @floatFromInt(try self.rng.uintBelow(120))),
            .y = 20 + @as(f32, @floatFromInt(try self.rng.uintBelow(48))),
        };
    }

    fn collectsPickup(self: Game) bool {
        const dx = self.player.x - self.pickup.x;
        const dy = self.player.y - self.pickup.y;
        return dx * dx + dy * dy <= 100;
    }

    fn loadBestScore(self: *Game, ctx: *up.core.GameContext) void {
        const saves = ctx.save_data orelse return;
        var bytes: [4]u8 = undefined;
        const stored = saves.read("best-score", &bytes) catch return;
        if (stored.len != bytes.len) return;
        self.best_score = std.mem.readInt(u32, &bytes, .little);
    }

    fn saveBestScore(self: *const Game, ctx: *up.core.GameContext) void {
        const saves = ctx.save_data orelse return;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, self.best_score, .little);
        // Save availability is an environmental concern. A failed write keeps
        // the current run playable and leaves the in-memory best score intact.
        saves.write("best-score", &bytes) catch {};
    }
};

test "Seed Sprint replays seeded movement into a pickup and one Canvas trace" {
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(std.testing.allocator, 60, default_seed);
    defer recorder.deinit();
    var input = up.input.Input{};

    // Seed 42 begins with a pickup at (106, 61). Sixteen diagonal fixed
    // updates place the player at (96, 61), inside the collection radius.
    for (0..16) |_| {
        input.beginFrame();
        input.set(.right, true);
        input.set(.down, true);
        try recorder.record(input);
    }
    var replay = try recorder.finish();
    defer replay.deinit(std.testing.allocator);

    var first = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer first.deinit();
    try first.runReplay(replay);
    const first_capture = first.capture();

    var second = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer second.deinit();
    try second.runReplay(replay);
    const second_capture = second.capture();

    try std.testing.expectEqual(@as(u32, 1), first.game.score);
    try std.testing.expectEqual(@as(u32, 1), first.game.best_score);
    try std.testing.expectEqual(@as(f32, 96), first.game.player.x);
    try std.testing.expectEqual(@as(f32, 61), first.game.player.y);
    try std.testing.expectEqualDeep(first.game, second.game);
    try up.testSupport.expectCanvasTraceEqual(first_capture.canvas_trace, second_capture.canvas_trace);
    const first_trace_hash = try first_capture.canvas_trace.hash();
    // This is a compact golden for the final logical draw frame. Structural
    // comparison above keeps a future mismatch diagnosable at field level.
    try std.testing.expectEqual(@as(u64, 3_849_701_052_811_511_551), first_trace_hash);
    try std.testing.expectEqual(first_trace_hash, try second_capture.canvas_trace.hash());
}

test "Seed Sprint loads an explicitly injected in-memory best score" {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(std.testing.allocator);
    defer saves.deinit();
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 7, .little);
    try saves.capability().write("best-score", &bytes);

    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, saves.capability());
    defer runner.deinit();
    try std.testing.expectEqual(@as(u32, 7), runner.game.best_score);
}

test "Seed Sprint writes a new best score through its injected save store" {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(std.testing.allocator);
    defer saves.deinit();
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, saves.capability());
    defer runner.deinit();

    // Keep the proof about persistence narrow: place the player on the
    // deterministic initial pickup, then execute one ordinary fixed update.
    runner.game.player = runner.game.pickup;
    try runner.run(&.{.{}});

    var bytes: [4]u8 = undefined;
    const stored = try saves.capability().read("best-score", &bytes);
    try std.testing.expectEqual(@as(usize, 4), stored.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &bytes, .little));
}

test "Seed Sprint initialization changes with its explicit seed" {
    var first = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer first.deinit();
    var second = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed + 1);
    defer second.deinit();
    try std.testing.expect(first.game.pickup.x != second.game.pickup.x or first.game.pickup.y != second.game.pickup.y);
}

test "Seed Sprint's external dependency exposes software render surfaces" {
    var surface = try up.graphics.RenderSurface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();
    surface.canvas().clear(up.core.Color.rgb(255, 198, 74));
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, 2, 2);
    defer canvas.deinit();
    try canvas.drawSurface(&surface, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    try std.testing.expectEqual(up.core.Color.rgb(255, 198, 74), canvas.get(1, 1).?);
}
