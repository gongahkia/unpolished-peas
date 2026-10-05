const std = @import("std");
const atlas = @import("atlas.zig");

/// One immutable atlas-frame step in a deterministic sprite animation clip.
/// `ticks` is the number of fixed simulation updates for which `frame` stays
/// current. It must be non-zero.
pub const SpriteAnimationStep = struct {
    frame: atlas.AtlasFrameHandle,
    ticks: u32,
};

/// Playback behavior after the final step of a clip.
pub const SpriteAnimationMode = enum {
    loop,
    once,
};

/// Immutable, game-owned sprite-frame animation data.
///
/// A clip borrows its step slice, so a game will normally declare the steps
/// as `const` static data and store the clip by value. It owns no image, Atlas,
/// renderer, clock, or allocation. Validate it once before constructing a
/// player.
pub const SpriteAnimationClip = struct {
    steps: []const SpriteAnimationStep,
    mode: SpriteAnimationMode = .loop,

    pub const Error = error{
        EmptySpriteAnimationClip,
        ZeroSpriteAnimationStepDuration,
        SpriteAnimationDurationOverflow,
        InvalidSpriteAnimationFrame,
    };

    pub fn init(steps: []const SpriteAnimationStep, mode: SpriteAnimationMode) Error!SpriteAnimationClip {
        const clip: SpriteAnimationClip = .{ .steps = steps, .mode = mode };
        try clip.validate();
        return clip;
    }

    pub fn validate(self: SpriteAnimationClip) Error!void {
        if (self.steps.len == 0) return error.EmptySpriteAnimationClip;
        _ = try self.totalTicks();
    }

    /// Validates handles when the owning Atlas is available. This preserves
    /// clip ownership independence while turning a bad static frame index into
    /// a recoverable initialization error rather than a later draw assertion.
    pub fn validateForAtlas(self: SpriteAnimationClip, value: *const atlas.Atlas) Error!void {
        try self.validate();
        for (self.steps) |step| {
            if (step.frame.index >= value.frames.len) return error.InvalidSpriteAnimationFrame;
        }
    }

    /// The duration of one loop cycle. It is public because it is useful for
    /// game-side diagnostics, not because a player needs wall-clock time.
    pub fn totalTicks(self: SpriteAnimationClip) Error!u64 {
        var total: u64 = 0;
        for (self.steps) |step| {
            if (step.ticks == 0) return error.ZeroSpriteAnimationStepDuration;
            total = std.math.add(u64, total, step.ticks) catch return error.SpriteAnimationDurationOverflow;
        }
        return total;
    }
};

/// Mutable, value-semantic playback state for one `SpriteAnimationClip`.
///
/// Call `advance(1)` from every fixed-step `Game.update`, then use
/// `currentFrame()` with the ordinary Atlas/Canvas draw API. Copying a player
/// copies its independent playback state; neither the player nor its clip
/// allocates in update or draw paths.
pub const SpriteAnimationPlayer = struct {
    clip: *const SpriteAnimationClip,
    step_index: usize = 0,
    ticks_in_step: u32 = 0,
    paused: bool = false,
    complete: bool = false,
    cycle_ticks: u64,

    pub fn init(clip: *const SpriteAnimationClip) SpriteAnimationClip.Error!SpriteAnimationPlayer {
        return .{ .clip = clip, .cycle_ticks = try clip.totalTicks() };
    }

    /// Switches to `clip` and restarts it, including when it is already the
    /// current clip. Game code owns the decision to switch idle/walk/attack.
    pub fn play(self: *SpriteAnimationPlayer, clip: *const SpriteAnimationClip) SpriteAnimationClip.Error!void {
        const cycle_ticks = try clip.totalTicks();
        self.clip = clip;
        self.cycle_ticks = cycle_ticks;
        self.restart();
    }

    pub fn pause(self: *SpriteAnimationPlayer) void {
        self.paused = true;
    }

    /// Zig reserves `resume`, so this keeps the ordinary pause/resume concept
    /// readable without requiring an escaped identifier at call sites.
    pub fn resumePlayback(self: *SpriteAnimationPlayer) void {
        self.paused = false;
    }

    pub fn restart(self: *SpriteAnimationPlayer) void {
        self.step_index = 0;
        self.ticks_in_step = 0;
        self.paused = false;
        self.complete = false;
    }

    pub fn isPaused(self: SpriteAnimationPlayer) bool {
        return self.paused;
    }

    /// Lets a game select an idle/walk/attack clip each fixed update without
    /// repeatedly restarting a clip that is already playing.
    pub fn isCurrentClip(self: SpriteAnimationPlayer, clip: *const SpriteAnimationClip) bool {
        return self.clip == clip;
    }

    /// A once clip remains on its final step after completion.
    pub fn isFinished(self: SpriteAnimationPlayer) bool {
        return self.complete;
    }

    pub fn currentStepIndex(self: SpriteAnimationPlayer) usize {
        return self.step_index;
    }

    pub fn currentFrame(self: SpriteAnimationPlayer) atlas.AtlasFrameHandle {
        return self.clip.steps[self.step_index].frame;
    }

    /// Advances an exact number of simulation ticks. This never reads a wall
    /// clock and does not mutate rendering state. Large loop advances skip
    /// complete cycles rather than iterating one tick at a time.
    pub fn advance(self: *SpriteAnimationPlayer, ticks: u32) void {
        if (ticks == 0 or self.paused or self.complete) return;

        var remaining: u64 = ticks;
        while (remaining > 0) {
            const duration = self.clip.steps[self.step_index].ticks;
            const until_next = @as(u64, duration - self.ticks_in_step);
            if (remaining < until_next) {
                self.ticks_in_step += @intCast(remaining);
                return;
            }

            remaining -= until_next;
            self.ticks_in_step = 0;
            if (self.step_index + 1 < self.clip.steps.len) {
                self.step_index += 1;
                continue;
            }

            switch (self.clip.mode) {
                .once => {
                    self.complete = true;
                    self.step_index = self.clip.steps.len - 1;
                    return;
                },
                .loop => {
                    self.step_index = 0;
                    if (remaining >= self.cycle_ticks) remaining %= self.cycle_ticks;
                },
            }
        }
    }
};

test "sprite animation validates clip data" {
    const frame: atlas.AtlasFrameHandle = .{ .index = 0 };
    try std.testing.expectError(error.EmptySpriteAnimationClip, SpriteAnimationClip.init(&.{}, .loop));
    try std.testing.expectError(error.ZeroSpriteAnimationStepDuration, SpriteAnimationClip.init(&.{.{ .frame = frame, .ticks = 0 }}, .loop));

    const clip = try SpriteAnimationClip.init(&.{ .{ .frame = frame, .ticks = 3 }, .{ .frame = .{ .index = 2 }, .ticks = 5 } }, .loop);
    try std.testing.expectEqual(@as(u64, 8), try clip.totalTicks());
}

test "sprite animation loop and once modes have exact fixed-tick behavior" {
    const steps = [_]SpriteAnimationStep{
        .{ .frame = .{ .index = 4 }, .ticks = 2 },
        .{ .frame = .{ .index = 7 }, .ticks = 3 },
    };
    const looping = try SpriteAnimationClip.init(&steps, .loop);
    var loop_player = try SpriteAnimationPlayer.init(&looping);
    try std.testing.expectEqual(@as(usize, 4), loop_player.currentFrame().index);
    loop_player.advance(2);
    try std.testing.expectEqual(@as(usize, 7), loop_player.currentFrame().index);
    loop_player.advance(3);
    try std.testing.expectEqual(@as(usize, 4), loop_player.currentFrame().index);
    loop_player.advance(10_007);
    try std.testing.expectEqual(@as(usize, 7), loop_player.currentFrame().index);
    try std.testing.expect(!loop_player.isFinished());
    const before_zero_advance = loop_player.currentStepIndex();
    loop_player.advance(0);
    try std.testing.expectEqual(before_zero_advance, loop_player.currentStepIndex());
    loop_player.advance(std.math.maxInt(u32));
    try std.testing.expect(loop_player.currentStepIndex() < steps.len);
    try std.testing.expect(loop_player.ticks_in_step < steps[loop_player.currentStepIndex()].ticks);

    const one_shot = try SpriteAnimationClip.init(&steps, .once);
    var once_player = try SpriteAnimationPlayer.init(&one_shot);
    once_player.advance(5);
    try std.testing.expect(once_player.isFinished());
    try std.testing.expectEqual(@as(usize, 7), once_player.currentFrame().index);
    once_player.advance(100);
    try std.testing.expectEqual(@as(usize, 7), once_player.currentFrame().index);
}

test "sprite animation pause resume restart switching and value copies are independent" {
    const first_steps = [_]SpriteAnimationStep{
        .{ .frame = .{ .index = 1 }, .ticks = 1 },
        .{ .frame = .{ .index = 2 }, .ticks = 1 },
    };
    const second_steps = [_]SpriteAnimationStep{.{ .frame = .{ .index = 8 }, .ticks = 4 }};
    const first = try SpriteAnimationClip.init(&first_steps, .loop);
    const second = try SpriteAnimationClip.init(&second_steps, .once);
    var player = try SpriteAnimationPlayer.init(&first);
    player.pause();
    player.advance(1);
    try std.testing.expectEqual(@as(usize, 1), player.currentFrame().index);
    player.resumePlayback();
    player.advance(1);
    try std.testing.expectEqual(@as(usize, 2), player.currentFrame().index);
    var copy = player;
    copy.advance(1);
    try std.testing.expectEqual(@as(usize, 1), copy.currentFrame().index);
    try std.testing.expectEqual(@as(usize, 2), player.currentFrame().index);
    try player.play(&second);
    try std.testing.expect(player.isCurrentClip(&second));
    try std.testing.expectEqual(@as(usize, 8), player.currentFrame().index);
    player.advance(4);
    try std.testing.expect(player.isFinished());
    player.restart();
    try std.testing.expect(!player.isFinished());
    try std.testing.expectEqual(@as(usize, 8), player.currentFrame().index);

    const invalid = SpriteAnimationClip{ .steps = &.{.{ .frame = .{ .index = 9 }, .ticks = 0 }}, .mode = .loop };
    try std.testing.expectError(error.ZeroSpriteAnimationStepDuration, player.play(&invalid));
    try std.testing.expect(player.isCurrentClip(&second));
}

test "sprite animation frame handles draw through the ordinary Atlas API" {
    const Color = @import("color.zig").Color;
    const Canvas = @import("canvas.zig").Canvas;

    const pixels = try std.testing.allocator.dupe(Color, &[_]Color{ Color.rgb(255, 0, 0), Color.rgb(0, 255, 0) });
    var value = try atlas.Atlas.init(std.testing.allocator, .{ .allocator = std.testing.allocator, .width = 2, .height = 1, .pixels = pixels }, "memory", &.{ .{ .name = "red", .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .name = "green", .x = 1, .y = 0, .w = 1, .h = 1 } }, &.{});
    defer value.deinit();
    const steps = [_]SpriteAnimationStep{ .{ .frame = .{ .index = 0 }, .ticks = 1 }, .{ .frame = .{ .index = 1 }, .ticks = 1 } };
    const clip = try SpriteAnimationClip.init(&steps, .loop);
    var player = try SpriteAnimationPlayer.init(&clip);
    var canvas = try Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    canvas.drawAtlasFrame(value, player.currentFrame(), 0, 0, .{});
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(0, 0).?);
    player.advance(1);
    canvas.clear(Color.black);
    canvas.drawAtlasFrame(value, player.currentFrame(), 0, 0, .{});
    try std.testing.expectEqual(Color.rgb(0, 255, 0), canvas.get(0, 0).?);

    const invalid = try SpriteAnimationClip.init(&.{.{ .frame = .{ .index = 2 }, .ticks = 1 }}, .loop);
    try std.testing.expectError(error.InvalidSpriteAnimationFrame, invalid.validateForAtlas(&value));
}
