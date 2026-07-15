const std = @import("std");
const StepClock = @import("app.zig").StepClock;
const Input = @import("input.zig").Input;
const Key = @import("input.zig").Key;
const PointerButton = @import("input.zig").PointerButton;

pub const max_frames: usize = 100_000;
pub const Button = enum(u3) { left, right, up, down, action, cancel, start, select };

pub const Frame = struct {
    buttons: u8,

    pub fn fromInput(state: Input) Frame {
        var result = Frame{ .buttons = 0 };
        inline for (button_keys, 0..) |key, index| {
            if (state.isDown(key)) result.buttons |= @as(u8, 1) << @intCast(index);
        }
        return result;
    }

    pub fn isDown(self: Frame, button: Button) bool {
        return (self.buttons & (@as(u8, 1) << @intFromEnum(button))) != 0;
    }

    pub fn apply(self: Frame, state: *Input) void {
        inline for (@typeInfo(Key).@"enum".fields) |field| {
            const key: Key = @enumFromInt(field.value);
            state.set(key, switch (key) {
                .left => self.isDown(.left),
                .right => self.isDown(.right),
                .up => self.isDown(.up),
                .down => self.isDown(.down),
                .action => self.isDown(.action),
                .cancel => self.isDown(.cancel),
                .start => self.isDown(.start),
                .select => self.isDown(.select),
                .debug, .screenshot => false,
            });
        }
    }
};

const button_keys = [_]Key{ .left, .right, .up, .down, .action, .cancel, .start, .select };

pub const Replay = struct { // owns parsed frame storage returned by parse; call deinit once.
    fixed_hz: u32,
    frames: []Frame,

    pub fn deinit(self: *Replay, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }

    pub fn applyFrame(self: Replay, index: usize, state: *Input) !void {
        if (index >= self.frames.len) return error.ReplayFrameOutOfRange;
        state.beginFrame();
        state.pointer = .{};
        state.gamepads = .{null} ** 4;
        inline for (@typeInfo(PointerButton).@"enum".fields) |field| state.setPointerButton(@enumFromInt(field.value), false);
        self.frames[index].apply(state);
    }

    pub fn encode(self: Replay, allocator: std.mem.Allocator) ![]u8 {
        if (self.fixed_hz == 0 or self.frames.len == 0 or self.frames.len > max_frames) return error.InvalidReplay;
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try output.writer.print("UPR1 {d}\n", .{self.fixed_hz});
        var start: usize = 0;
        while (start < self.frames.len) {
            var end = start + 1;
            while (end < self.frames.len and self.frames[end].buttons == self.frames[start].buttons) : (end += 1) {}
            try output.writer.print("{d} {d}\n", .{ end - start, self.frames[start].buttons });
            start = end;
        }
        return allocator.dupe(u8, output.written());
    }
};

pub const Recorder = struct { // owns recorded frames until finish transfers them to a Replay; call deinit once.
    allocator: std.mem.Allocator,
    fixed_hz: u32,
    frames: std.ArrayListUnmanaged(Frame) = .{},

    pub fn init(allocator: std.mem.Allocator, fixed_hz: u32) !Recorder {
        if (fixed_hz == 0) return error.InvalidReplay;
        return .{ .allocator = allocator, .fixed_hz = fixed_hz };
    }

    pub fn deinit(self: *Recorder) void {
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn record(self: *Recorder, state: Input) !void {
        if (self.frames.items.len == max_frames) return error.ReplayTooLong;
        try self.frames.append(self.allocator, Frame.fromInput(state));
    }

    pub fn finish(self: *Recorder) !Replay {
        if (self.frames.items.len == 0) return error.InvalidReplay;
        return .{ .fixed_hz = self.fixed_hz, .frames = try self.frames.toOwnedSlice(self.allocator) };
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Replay {
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    const header = std.mem.trimRight(u8, lines.next() orelse return error.InvalidReplay, "\r");
    var fields = std.mem.tokenizeScalar(u8, header, ' ');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidReplay, "UPR1")) return error.InvalidReplay;
    const fixed_hz = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidReplay, 10);
    if (fixed_hz == 0 or fields.next() != null) return error.InvalidReplay;
    var output = std.ArrayListUnmanaged(Frame){};
    errdefer output.deinit(allocator);
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var run = std.mem.tokenizeScalar(u8, line, ' ');
        const count = try std.fmt.parseInt(usize, run.next() orelse return error.InvalidReplay, 10);
        const buttons = try std.fmt.parseInt(u8, run.next() orelse return error.InvalidReplay, 10);
        if (count == 0 or run.next() != null or output.items.len + count > max_frames) return error.InvalidReplay;
        try output.ensureUnusedCapacity(allocator, count);
        for (0..count) |_| output.appendAssumeCapacity(.{ .buttons = buttons });
    }
    if (output.items.len == 0) return error.InvalidReplay;
    return .{ .fixed_hz = fixed_hz, .frames = try output.toOwnedSlice(allocator) };
}

test "replay expands deterministic run-length input" {
    var replay = try parse(std.testing.allocator, "UPR1 60\n2 1\n1 4\n");
    defer replay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 60), replay.fixed_hz);
    try std.testing.expectEqualSlices(Frame, &.{ .{ .buttons = 1 }, .{ .buttons = 1 }, .{ .buttons = 4 } }, replay.frames);
}

test "replay accepts CRLF line endings" {
    var replay = try parse(std.testing.allocator, "UPR1 60\r\n2 1\r\n");
    defer replay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 60), replay.fixed_hz);
    try std.testing.expectEqualSlices(Frame, &.{ .{ .buttons = 1 }, .{ .buttons = 1 } }, replay.frames);
}

test "recorder normalizes input and reproduces fixed-step state hashes" {
    var recorder = try Recorder.init(std.testing.allocator, 60);
    defer recorder.deinit();
    var source = Input{};
    source.set(.left, true);
    source.set(.action, true);
    try recorder.record(source);
    source.beginFrame();
    source.set(.left, false);
    source.set(.right, true);
    source.set(.action, false);
    try recorder.record(source);
    source.beginFrame();
    source.set(.right, false);
    source.set(.up, true);
    source.set(.cancel, true);
    try recorder.record(source);
    source.beginFrame();
    try recorder.record(source);
    var replay = try recorder.finish();
    defer replay.deinit(std.testing.allocator);
    const encoded = try replay.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("UPR1 60\n1 17\n1 2\n2 36\n", encoded);
    var parsed = try parse(std.testing.allocator, encoded);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Frame, replay.frames, parsed.frames);
    const expected_hash: u64 = 0xce04c4a682059360;
    try std.testing.expectEqual(expected_hash, try fixedStepStateHash(replay));
    try std.testing.expectEqual(expected_hash, try fixedStepStateHash(parsed));
}

fn fixedStepStateHash(replay: Replay) !u64 {
    var clock = StepClock.init(replay.fixed_hz);
    var input = Input{};
    var position: i32 = 0;
    var hash = std.hash.Fnv1a_64.init();
    for (replay.frames, 0..) |_, index| {
        try replay.applyFrame(index, &input);
        const steps = clock.push(clock.step_seconds);
        for (0..steps) |_| {
            if (input.isDown(.left)) position -= 1;
            if (input.isDown(.right)) position += 1;
            if (input.isDown(.up)) position += 10;
            if (input.wasPressed(.action)) position += 100;
            if (input.wasPressed(.cancel)) position -= 1_000;
            hash.update(std.mem.asBytes(&position));
        }
    }
    return hash.final();
}
