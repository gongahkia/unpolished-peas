const std = @import("std");
const StepClock = @import("app.zig").StepClock;
const Input = @import("input.zig").Input;
const Key = @import("input.zig").Key;
const Gamepad = @import("input.zig").Gamepad;
const Vec2 = @import("math.zig").Vec2;
const rng = @import("rng.zig");

pub const max_frames: usize = 100_000;
pub const Button = enum(u3) { left, right, up, down, action, cancel, start, select };

/// The current replay payload. It contains only normalized game-facing input;
/// no SDL, DOM, window, or renderer handles are stored.
pub const Frame = Input.Snapshot;

pub const Reproduction = struct {
    frames: usize,
    fixed_hz: u32,
    updates: u64,
    hash: u64,
};

const magic_v2 = "UPR2";
const magic_v3 = "UPR3";
const magic_v4 = "UPR4";
const header_bytes_v2: usize = 12;
const header_bytes_v3: usize = 24;
const header_bytes_v4: usize = 28;
const encoded_frame_bytes: usize = 290;

pub const Replay = struct { // owns parsed frame storage returned by parse; call deinit once.
    pub const Environment = @import("replay_environment.zig").Environment;
    fixed_hz: u32,
    frames: []Frame,
    /// Present only when this replay was recorded with an explicit Peas
    /// simulation seed. UPR1 and UPR2 replays intentionally leave it null.
    simulation_seed: ?u64 = null,
    /// The algorithm that initialized a seed-bearing replay. Peas currently
    /// supports only `DeterministicRng.algorithm`.
    rng_algorithm: ?rng.Algorithm = null,
    /// Optional owned build identity and initial saves, captured before init.
    /// Only session recordings carry this UPR4 metadata.
    environment: ?Environment = null,

    pub fn deinit(self: *Replay, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        if (self.environment) |*environment| environment.deinit(allocator);
        self.* = undefined;
    }

    /// Validates the complete recording before a runner changes game state.
    pub fn validate(self: Replay) !void {
        try validateReplay(self);
    }

    /// Applies the complete normalized state for one fixed simulation tick.
    /// Call this immediately before the corresponding game update.
    pub fn applyFrame(self: Replay, index: usize, state: *Input) !void {
        if (index >= self.frames.len) return error.ReplayFrameOutOfRange;
        self.frames[index].apply(state);
    }

    /// Produces fixed-width, little-endian replay data. Seedless replays emit
    /// UPR2; seed-bearing replays emit UPR3 with an explicit algorithm ID and
    /// seed. Session recordings emit UPR4 with initial saves and identity.
    /// All earlier formats remain readable through `parse`.
    pub fn encode(self: Replay, allocator: std.mem.Allocator) ![]u8 {
        try validateReplay(self);
        const seeded = self.simulation_seed != null;
        const environment_bytes = if (self.environment) |environment| try environment.encode(allocator) else null;
        defer if (environment_bytes) |bytes| allocator.free(bytes);
        const environment_len = if (environment_bytes) |bytes| bytes.len else 0;
        const header_bytes = if (environment_bytes != null) header_bytes_v4 else if (seeded) header_bytes_v3 else header_bytes_v2;
        const byte_count = header_bytes + environment_len + self.frames.len * encoded_frame_bytes;
        const output = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(output);
        @memcpy(output[0..4], if (environment_bytes != null) magic_v4 else if (seeded) magic_v3 else magic_v2);
        std.mem.writeInt(u32, output[4..8], self.fixed_hz, .little);
        if (seeded) {
            std.mem.writeInt(u32, output[8..12], @intFromEnum(self.rng_algorithm.?), .little);
            std.mem.writeInt(u64, output[12..20], self.simulation_seed.?, .little);
            std.mem.writeInt(u32, output[20..24], @intCast(self.frames.len), .little);
        } else {
            std.mem.writeInt(u32, output[8..12], @intCast(self.frames.len), .little);
        }
        if (environment_bytes) |bytes| {
            std.mem.writeInt(u32, output[24..28], @intCast(bytes.len), .little);
            @memcpy(output[header_bytes..][0..bytes.len], bytes);
        }
        var writer = ByteWriter{ .bytes = output[header_bytes + environment_len ..] };
        for (self.frames) |frame| try writer.frame(frame);
        std.debug.assert(writer.index == writer.bytes.len);
        return output;
    }
};

pub const Recorder = struct { // owns recorded frames until finish transfers them to a Replay; call deinit once.
    allocator: std.mem.Allocator,
    fixed_hz: u32,
    simulation_seed: ?u64 = null,
    rng_algorithm: ?rng.Algorithm = null,
    environment: ?Replay.Environment = null,
    frames: std.ArrayListUnmanaged(Frame) = .{},

    pub fn init(allocator: std.mem.Allocator, fixed_hz: u32) !Recorder {
        if (fixed_hz == 0) return error.InvalidReplay;
        return .{ .allocator = allocator, .fixed_hz = fixed_hz };
    }

    /// Records input for a run initialized with Peas's current deterministic
    /// RNG contract. The resulting UPR3 replay carries this seed explicitly.
    pub fn initSeeded(allocator: std.mem.Allocator, fixed_hz: u32, simulation_seed: u64) !Recorder {
        var result = try init(allocator, fixed_hz);
        result.simulation_seed = simulation_seed;
        result.rng_algorithm = rng.DeterministicRng.algorithm;
        return result;
    }

    /// Begin before Game.init. Copies the selected save values and identifiers
    /// now, so writes during gameplay cannot change this recording's start.
    pub fn initSession(allocator: std.mem.Allocator, fixed_hz: u32, simulation_seed: u64, options: Replay.Environment.CaptureOptions) !Recorder {
        var result = try initSeeded(allocator, fixed_hz, simulation_seed);
        result.environment = try Replay.Environment.capture(allocator, options);
        return result;
    }

    pub fn deinit(self: *Recorder) void {
        self.frames.deinit(self.allocator);
        if (self.environment) |*environment| environment.deinit(self.allocator);
        self.* = undefined;
    }

    /// Records the state observed by a game during one fixed update.
    pub fn record(self: *Recorder, state: Input) !void {
        if (self.frames.items.len == max_frames) return error.ReplayTooLong;
        const frame = state.snapshot();
        if (!frame.isFinite()) return error.InvalidReplayInput;
        try self.frames.append(self.allocator, frame);
    }

    pub fn finish(self: *Recorder) !Replay {
        if (self.frames.items.len == 0) return error.InvalidReplay;
        var environment = if (self.environment) |value| try value.clone(self.allocator) else null;
        errdefer if (environment) |*value| value.deinit(self.allocator);
        return .{
            .fixed_hz = self.fixed_hz,
            .frames = try self.frames.toOwnedSlice(self.allocator),
            .simulation_seed = self.simulation_seed,
            .rng_algorithm = self.rng_algorithm,
            .environment = environment,
        };
    }
};

/// Parses UPR4 session data, UPR3 seed-bearing data, UPR2 seedless data, or older
/// UPR1 run-length text fixtures. UPR1 carries only held action keys; its
/// edges are reconstructed from successive held states.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Replay {
    if (source.len >= magic_v4.len and std.mem.eql(u8, source[0..magic_v4.len], magic_v4)) return parseSeeded(allocator, source, true);
    if (source.len >= magic_v3.len and std.mem.eql(u8, source[0..magic_v3.len], magic_v3)) return parseSeeded(allocator, source, false);
    if (source.len >= magic_v2.len and std.mem.eql(u8, source[0..magic_v2.len], magic_v2)) return parseV2(allocator, source);
    return parseV1(allocator, source);
}

pub fn reproduce(replay: Replay) !Reproduction {
    var clock = StepClock.init(replay.fixed_hz);
    var input = Input{};
    var updates: u64 = 0;
    var hash = std.hash.Fnv1a_64.init();
    hash.update(std.mem.asBytes(&replay.fixed_hz));
    for (replay.frames, 0..) |_, index| {
        try replay.applyFrame(index, &input);
        const steps = clock.push(clock.step_seconds);
        for (0..steps) |_| {
            inline for (@typeInfo(Key).@"enum".fields) |field| {
                const key: Key = @enumFromInt(field.value);
                hash.update(&.{@intFromBool(input.isDown(key))});
            }
            updates += 1;
        }
    }
    return .{ .frames = replay.frames.len, .fixed_hz = replay.fixed_hz, .updates = updates, .hash = hash.final() };
}

fn parseV2(allocator: std.mem.Allocator, source: []const u8) !Replay {
    if (source.len < header_bytes_v2) return error.InvalidReplay;
    const fixed_hz = std.mem.readInt(u32, source[4..8], .little);
    const frame_count_u32 = std.mem.readInt(u32, source[8..12], .little);
    if (fixed_hz == 0 or frame_count_u32 == 0 or frame_count_u32 > max_frames) return error.InvalidReplay;
    const frame_count: usize = @intCast(frame_count_u32);
    const expected_bytes = header_bytes_v2 + frame_count * encoded_frame_bytes;
    if (source.len != expected_bytes) return error.InvalidReplay;

    const frames = try allocator.alloc(Frame, frame_count);
    errdefer allocator.free(frames);
    var reader = ByteReader{ .bytes = source[header_bytes_v2..] };
    for (frames) |*frame| {
        frame.* = try reader.frame();
        if (!frame.isFinite()) return error.InvalidReplay;
    }
    std.debug.assert(reader.index == reader.bytes.len);
    return .{ .fixed_hz = fixed_hz, .frames = frames };
}

fn parseSeeded(allocator: std.mem.Allocator, source: []const u8, has_environment: bool) !Replay {
    const header_bytes = if (has_environment) header_bytes_v4 else header_bytes_v3;
    if (source.len < header_bytes) return error.InvalidReplay;
    const fixed_hz = std.mem.readInt(u32, source[4..8], .little);
    const algorithm_id = std.mem.readInt(u32, source[8..12], .little);
    const algorithm = std.meta.intToEnum(rng.Algorithm, algorithm_id) catch return error.UnsupportedReplayRng;
    if (algorithm != rng.DeterministicRng.algorithm) return error.UnsupportedReplayRng;
    const simulation_seed = std.mem.readInt(u64, source[12..20], .little);
    const frame_count_u32 = std.mem.readInt(u32, source[20..24], .little);
    if (fixed_hz == 0 or frame_count_u32 == 0 or frame_count_u32 > max_frames) return error.InvalidReplay;
    const frame_count: usize = @intCast(frame_count_u32);
    const environment_len = if (has_environment) std.mem.readInt(u32, source[24..28], .little) else 0;
    if (environment_len > Replay.Environment.max_encoded_bytes) return error.ReplayEnvironmentTooLarge;
    const expected_bytes = header_bytes + environment_len + frame_count * encoded_frame_bytes;
    if (source.len != expected_bytes) return error.InvalidReplay;

    const frames = try allocator.alloc(Frame, frame_count);
    errdefer allocator.free(frames);
    var environment = if (has_environment) try Replay.Environment.parse(allocator, source[header_bytes..][0..environment_len]) else null;
    errdefer if (environment) |*value| value.deinit(allocator);
    var reader = ByteReader{ .bytes = source[header_bytes + environment_len ..] };
    for (frames) |*frame| {
        frame.* = try reader.frame();
        if (!frame.isFinite()) return error.InvalidReplay;
    }
    std.debug.assert(reader.index == reader.bytes.len);
    return .{
        .fixed_hz = fixed_hz,
        .frames = frames,
        .simulation_seed = simulation_seed,
        .rng_algorithm = algorithm,
        .environment = environment,
    };
}

fn parseV1(allocator: std.mem.Allocator, source: []const u8) !Replay {
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    const header = std.mem.trimRight(u8, lines.next() orelse return error.InvalidReplay, "\r");
    var fields = std.mem.tokenizeScalar(u8, header, ' ');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidReplay, "UPR1")) return error.InvalidReplay;
    const fixed_hz = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidReplay, 10);
    if (fixed_hz == 0 or fields.next() != null) return error.InvalidReplay;
    var output = std.ArrayListUnmanaged(Frame){};
    errdefer output.deinit(allocator);
    var previous_buttons: u8 = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var run = std.mem.tokenizeScalar(u8, line, ' ');
        const count = try std.fmt.parseInt(usize, run.next() orelse return error.InvalidReplay, 10);
        const buttons = try std.fmt.parseInt(u8, run.next() orelse return error.InvalidReplay, 10);
        if (count == 0 or run.next() != null or count > max_frames - output.items.len) return error.InvalidReplay;
        try output.ensureUnusedCapacity(allocator, count);
        for (0..count) |_| {
            output.appendAssumeCapacity(legacyFrame(previous_buttons, buttons));
            previous_buttons = buttons;
        }
    }
    if (output.items.len == 0) return error.InvalidReplay;
    return .{ .fixed_hz = fixed_hz, .frames = try output.toOwnedSlice(allocator) };
}

fn legacyFrame(previous_buttons: u8, buttons: u8) Frame {
    var frame = Frame{};
    inline for (button_keys, 0..) |key, index| {
        const bit = @as(u8, 1) << @intCast(index);
        const was_down = (previous_buttons & bit) != 0;
        const is_down = (buttons & bit) != 0;
        const key_index = @intFromEnum(key);
        frame.down[key_index] = is_down;
        frame.pressed[key_index] = is_down and !was_down;
        frame.released[key_index] = was_down and !is_down;
    }
    return frame;
}

const button_keys = [_]Key{ .left, .right, .up, .down, .action, .cancel, .start, .select };

fn validateReplay(replay: Replay) !void {
    if (replay.fixed_hz == 0 or replay.frames.len == 0 or replay.frames.len > max_frames) return error.InvalidReplay;
    if (replay.simulation_seed == null) {
        if (replay.rng_algorithm != null) return error.InvalidReplay;
    } else {
        const algorithm = replay.rng_algorithm orelse return error.InvalidReplay;
        if (algorithm != rng.DeterministicRng.algorithm) return error.UnsupportedReplayRng;
    }
    for (replay.frames) |frame| if (!frame.isFinite()) return error.InvalidReplay;
    if (replay.environment) |environment| {
        if (replay.simulation_seed == null) return error.InvalidReplay;
        try environment.validate();
    }
}

const ByteWriter = struct {
    bytes: []u8,
    index: usize = 0,

    fn byte(self: *ByteWriter, value: u8) !void {
        if (self.index >= self.bytes.len) return error.InvalidReplay;
        self.bytes[self.index] = value;
        self.index += 1;
    }

    fn writeU16(self: *ByteWriter, value: u16) !void {
        if (self.index + 2 > self.bytes.len) return error.InvalidReplay;
        std.mem.writeInt(u16, self.bytes[self.index..][0..2], value, .little);
        self.index += 2;
    }

    fn writeI32(self: *ByteWriter, value: i32) !void {
        if (self.index + 4 > self.bytes.len) return error.InvalidReplay;
        std.mem.writeInt(i32, self.bytes[self.index..][0..4], value, .little);
        self.index += 4;
    }

    fn writeF32(self: *ByteWriter, value: f32) !void {
        if (!std.math.isFinite(value) or self.index + 4 > self.bytes.len) return error.InvalidReplay;
        std.mem.writeInt(u32, self.bytes[self.index..][0..4], @bitCast(value), .little);
        self.index += 4;
    }

    fn frame(self: *ByteWriter, value: Frame) !void {
        try self.writeU16(boolMask(value.down));
        try self.writeU16(boolMask(value.pressed));
        try self.writeU16(boolMask(value.released));
        try self.byte(boolMask(value.pointer_down));
        try self.byte(boolMask(value.pointer_pressed));
        try self.byte(boolMask(value.pointer_released));
        try self.byte(@intFromBool(value.pointer.canvas != null));
        try self.writeF32(value.pointer.window.x);
        try self.writeF32(value.pointer.window.y);
        try self.writeF32(value.pointer.framebuffer.x);
        try self.writeF32(value.pointer.framebuffer.y);
        const canvas = value.pointer.canvas orelse Vec2{};
        try self.writeF32(canvas.x);
        try self.writeF32(canvas.y);
        try self.writeF32(value.pointer.delta.x);
        try self.writeF32(value.pointer.delta.y);
        try self.writeF32(value.pointer.wheel.x);
        try self.writeF32(value.pointer.wheel.y);
        for (value.gamepads) |slot| {
            try self.byte(@intFromBool(slot != null));
            if (slot) |pad| {
                try self.writeI32(pad.id);
                try self.byte(@intFromBool(pad.connected));
                try self.writeU16(boolMask(pad.buttons));
                try self.writeU16(boolMask(pad.pressed));
                try self.writeU16(boolMask(pad.released));
                for (pad.axes) |axis| try self.writeF32(axis);
                for (pad.previous_axes) |axis| try self.writeF32(axis);
            } else {
                try self.writeI32(0);
                try self.byte(0);
                try self.writeU16(0);
                try self.writeU16(0);
                try self.writeU16(0);
                for (0..12) |_| try self.writeF32(0);
            }
        }
    }
};

const ByteReader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn byte(self: *ByteReader) !u8 {
        if (self.index >= self.bytes.len) return error.InvalidReplay;
        const value = self.bytes[self.index];
        self.index += 1;
        return value;
    }

    fn readU16(self: *ByteReader) !u16 {
        if (self.index + 2 > self.bytes.len) return error.InvalidReplay;
        const value = std.mem.readInt(u16, self.bytes[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    fn readI32(self: *ByteReader) !i32 {
        if (self.index + 4 > self.bytes.len) return error.InvalidReplay;
        const value = std.mem.readInt(i32, self.bytes[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }

    fn readF32(self: *ByteReader) !f32 {
        if (self.index + 4 > self.bytes.len) return error.InvalidReplay;
        const bits = std.mem.readInt(u32, self.bytes[self.index..][0..4], .little);
        self.index += 4;
        return @bitCast(bits);
    }

    fn frame(self: *ByteReader) !Frame {
        var value = Frame{};
        try boolMaskInto(value.down[0..], try self.readU16());
        try boolMaskInto(value.pressed[0..], try self.readU16());
        try boolMaskInto(value.released[0..], try self.readU16());
        try boolMaskInto(value.pointer_down[0..], try self.byte());
        try boolMaskInto(value.pointer_pressed[0..], try self.byte());
        try boolMaskInto(value.pointer_released[0..], try self.byte());
        const has_canvas = switch (try self.byte()) {
            0 => false,
            1 => true,
            else => return error.InvalidReplay,
        };
        value.pointer.window = .{ .x = try self.readF32(), .y = try self.readF32() };
        value.pointer.framebuffer = .{ .x = try self.readF32(), .y = try self.readF32() };
        const canvas: Vec2 = .{ .x = try self.readF32(), .y = try self.readF32() };
        value.pointer.canvas = if (has_canvas) canvas else null;
        value.pointer.delta = .{ .x = try self.readF32(), .y = try self.readF32() };
        value.pointer.wheel = .{ .x = try self.readF32(), .y = try self.readF32() };
        for (&value.gamepads) |*slot| {
            const present = switch (try self.byte()) {
                0 => false,
                1 => true,
                else => return error.InvalidReplay,
            };
            const id = try self.readI32();
            const connected = switch (try self.byte()) {
                0 => false,
                1 => true,
                else => return error.InvalidReplay,
            };
            var pad = Gamepad{ .id = id, .connected = connected };
            try boolMaskInto(pad.buttons[0..], try self.readU16());
            try boolMaskInto(pad.pressed[0..], try self.readU16());
            try boolMaskInto(pad.released[0..], try self.readU16());
            for (&pad.axes) |*axis| axis.* = try self.readF32();
            for (&pad.previous_axes) |*axis| axis.* = try self.readF32();
            if (present) {
                slot.* = pad;
            } else if (id != 0 or connected or boolMask(pad.buttons) != 0 or boolMask(pad.pressed) != 0 or boolMask(pad.released) != 0 or !allZero(pad.axes[0..]) or !allZero(pad.previous_axes[0..])) {
                return error.InvalidReplay;
            }
        }
        return value;
    }
};

fn boolMask(values: anytype) @Type(.{ .int = .{ .signedness = .unsigned, .bits = @typeInfo(@TypeOf(values)).array.len } }) {
    const Mask = @Type(.{ .int = .{ .signedness = .unsigned, .bits = @typeInfo(@TypeOf(values)).array.len } });
    var result: Mask = 0;
    inline for (values, 0..) |value, index| {
        if (value) result |= @as(Mask, 1) << @intCast(index);
    }
    return result;
}

fn boolMaskInto(values: []bool, mask: anytype) !void {
    const max_bits = @bitSizeOf(@TypeOf(mask));
    if (values.len > max_bits) return error.InvalidReplay;
    var extra = mask;
    for (values, 0..) |*value, index| {
        value.* = (mask & (@as(@TypeOf(mask), 1) << @intCast(index))) != 0;
        extra &= ~(@as(@TypeOf(mask), 1) << @intCast(index));
    }
    if (extra != 0) return error.InvalidReplay;
}

fn allZero(values: []const f32) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

test "replay expands legacy deterministic run-length input" {
    var replay = try parse(std.testing.allocator, "UPR1 60\n2 1\n1 4\n");
    defer replay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 60), replay.fixed_hz);
    try std.testing.expectEqual(@as(usize, 3), replay.frames.len);
    try std.testing.expect(replay.frames[0].down[@intFromEnum(Key.left)]);
    try std.testing.expect(replay.frames[0].pressed[@intFromEnum(Key.left)]);
    try std.testing.expect(!replay.frames[1].pressed[@intFromEnum(Key.left)]);
    try std.testing.expect(replay.frames[2].released[@intFromEnum(Key.left)]);
    try std.testing.expect(replay.frames[2].down[@intFromEnum(Key.up)]);
}

test "replay accepts legacy CRLF line endings" {
    var replay = try parse(std.testing.allocator, "UPR1 60\r\n2 1\r\n");
    defer replay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 60), replay.fixed_hz);
    try std.testing.expectEqual(@as(usize, 2), replay.frames.len);
}

test "recorder round-trips full normalized input snapshots" {
    var recorder = try Recorder.init(std.testing.allocator, 60);
    defer recorder.deinit();
    var source = Input{};
    source.set(.left, true);
    source.setPointerPosition(.{ .x = 10, .y = 20 }, .{ .x = 20, .y = 40 }, .{ .x = 5, .y = 10 });
    source.setPointerButton(.left, true);
    source.addPointerWheel(.{ .y = -1 });
    try std.testing.expect(source.addGamepad(7));
    source.setGamepadButton(7, .south, true);
    source.setGamepadAxis(7, .left_x, 0.75, 0);
    try recorder.record(source);
    source.beginFrame();
    source.set(.left, false);
    source.setPointerButton(.left, false);
    source.addPointerWheel(.{ .x = 2 });
    source.setGamepadButton(7, .south, false);
    try recorder.record(source);

    var replay = try recorder.finish();
    defer replay.deinit(std.testing.allocator);
    const encoded = try replay.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(magic_v2, encoded[0..magic_v2.len]);
    try std.testing.expectEqual(header_bytes_v2 + encoded_frame_bytes * 2, encoded.len);
    var parsed = try parse(std.testing.allocator, encoded);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(replay.frames, parsed.frames);

    var applied = Input{};
    try parsed.applyFrame(0, &applied);
    try std.testing.expect(applied.wasPressed(.left));
    try std.testing.expect(applied.pointerWasPressed(.left));
    try std.testing.expectEqual(@as(f32, -1), applied.pointer.wheel.y);
    try std.testing.expectEqual(@as(f32, 0.75), applied.gamepad(7).?.axis(.left_x));
    try parsed.applyFrame(1, &applied);
    try std.testing.expect(applied.wasReleased(.left));
    try std.testing.expect(applied.pointerWasReleased(.left));
    try std.testing.expect(applied.gamepad(7).?.wasReleased(.south));
}

test "seeded recorder emits UPR3 without reinterpreting UPR2" {
    var recorder = try Recorder.initSeeded(std.testing.allocator, 120, 42);
    defer recorder.deinit();
    var input = Input{};
    input.set(.action, true);
    try recorder.record(input);
    var replay = try recorder.finish();
    defer replay.deinit(std.testing.allocator);
    const encoded = try replay.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(magic_v3, encoded[0..magic_v3.len]);
    try std.testing.expectEqual(header_bytes_v3 + encoded_frame_bytes, encoded.len);
    try std.testing.expectEqual(@as(u32, @intFromEnum(rng.DeterministicRng.algorithm)), std.mem.readInt(u32, encoded[8..12], .little));
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, encoded[12..20], .little));

    var parsed = try parse(std.testing.allocator, encoded);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 42), parsed.simulation_seed);
    try std.testing.expectEqual(@as(?rng.Algorithm, rng.DeterministicRng.algorithm), parsed.rng_algorithm);

    var old = try parse(std.testing.allocator, "UPR1 60\n1 1\n");
    defer old.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, null), old.simulation_seed);
    try std.testing.expectEqual(@as(?rng.Algorithm, null), old.rng_algorithm);
}

test "recorded input replays the same deterministic game state" {
    const Game = struct {
        x: i32 = 0,
        actions: u32 = 0,

        fn step(self: *@This(), input: Input) void {
            if (input.isDown(.right)) self.x += 1;
            if (input.isDown(.left)) self.x -= 1;
            if (input.wasPressed(.action)) self.actions += 1;
        }
    };
    var recorder = try Recorder.init(std.testing.allocator, 60);
    defer recorder.deinit();
    var live_input = Input{};
    var live = Game{};
    for (0..5) |tick| {
        live_input.beginFrame();
        switch (tick) {
            1 => live_input.set(.right, true),
            3 => live_input.set(.action, true),
            4 => {
                live_input.set(.right, false);
                live_input.set(.action, false);
            },
            else => {},
        }
        try recorder.record(live_input);
        live.step(live_input);
    }
    var replay = try recorder.finish();
    defer replay.deinit(std.testing.allocator);
    var replay_input = Input{};
    var replayed = Game{};
    for (replay.frames, 0..) |_, index| {
        try replay.applyFrame(index, &replay_input);
        replayed.step(replay_input);
    }
    try std.testing.expectEqualDeep(live, replayed);
}

test "replay rejects truncated and malformed binary payloads" {
    try std.testing.expectError(error.InvalidReplay, parse(std.testing.allocator, magic_v2));
    var recorder = try Recorder.init(std.testing.allocator, 60);
    defer recorder.deinit();
    try recorder.record(.{});
    var replay = try recorder.finish();
    defer replay.deinit(std.testing.allocator);
    const encoded = try replay.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.InvalidReplay, parse(std.testing.allocator, encoded[0 .. encoded.len - 1]));
    std.mem.writeInt(u32, encoded[header_bytes_v2 + 10 ..][0..4], 0x7fc00000, .little);
    try std.testing.expectError(error.InvalidReplay, parse(std.testing.allocator, encoded));
    std.mem.writeInt(u32, encoded[header_bytes_v2 + 10 ..][0..4], 0, .little);
    std.mem.writeInt(u32, encoded[8..12], @intCast(max_frames + 1), .little);
    try std.testing.expectError(error.InvalidReplay, parse(std.testing.allocator, encoded));
    std.mem.writeInt(u32, encoded[8..12], 1, .little);
    encoded[4] = 0;
    encoded[5] = 0;
    encoded[6] = 0;
    encoded[7] = 0;
    try std.testing.expectError(error.InvalidReplay, parse(std.testing.allocator, encoded));

    var seeded_recorder = try Recorder.initSeeded(std.testing.allocator, 60, 1);
    defer seeded_recorder.deinit();
    try seeded_recorder.record(.{});
    var seeded = try seeded_recorder.finish();
    defer seeded.deinit(std.testing.allocator);
    const seeded_encoded = try seeded.encode(std.testing.allocator);
    defer std.testing.allocator.free(seeded_encoded);
    std.mem.writeInt(u32, seeded_encoded[8..12], 99, .little);
    try std.testing.expectError(error.UnsupportedReplayRng, parse(std.testing.allocator, seeded_encoded));
}

test "replay reproduction yields a deterministic normalized input hash" {
    var replay = try parse(std.testing.allocator, "UPR1 60\n2 17\n1 2\n");
    defer replay.deinit(std.testing.allocator);
    const first = try reproduce(replay);
    const second = try reproduce(replay);
    try std.testing.expectEqual(@as(usize, 3), first.frames);
    try std.testing.expectEqual(@as(u64, 3), first.updates);
    try std.testing.expectEqual(first.hash, second.hash);
}

fn sessionRoundTrip(allocator: std.mem.Allocator) !void {
    var saves: @import("test_support.zig").InMemorySaveStore = undefined;
    saves.init(allocator);
    defer saves.deinit();
    try saves.capability().write("progress", &.{ 0, 255, 17 });
    try saves.capability().write("empty", "");
    const identity = Replay.Environment.Identity{ .game = "game", .build = "build-1", .assets = "assets-1" };
    var recorder = try Recorder.initSession(allocator, 60, 42, .{
        .identity = identity,
        .save_data = saves.capability(),
        .save_keys = &.{ "progress", "missing", "empty" },
    });
    defer recorder.deinit();
    // Changes made after capture must not alter the initial environment.
    try saves.capability().write("progress", "new progress");
    try recorder.record(.{});
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const bytes = try replay.encode(allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("UPR4", bytes[0..4]);
    var restored = try parse(allocator, bytes);
    defer restored.deinit(allocator);
    try std.testing.expectEqualDeep(replay, restored);
    const environment = restored.environment.?;
    try std.testing.expectEqualStrings("empty", environment.saves[0].key);
    try std.testing.expectEqual(@as(usize, 0), environment.saves[0].bytes.?.len);
    try std.testing.expectEqualStrings("missing", environment.saves[1].key);
    try std.testing.expect(environment.saves[1].bytes == null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 17 }, environment.saves[2].bytes.?);
}

test "session replay round trips identity and selected initial saves without leaks" {
    try sessionRoundTrip(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sessionRoundTrip, .{});
}

test "session replay rejects incomplete and unbounded environment data" {
    const allocator = std.testing.allocator;
    var recorder = try Recorder.initSession(allocator, 60, 42, .{
        .identity = .{ .game = "g", .build = "b", .assets = "a" },
    });
    defer recorder.deinit();
    try recorder.record(.{});
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const encoded = try replay.encode(allocator);
    defer allocator.free(encoded);
    // Wire-format golden independent of the decoder: UPR4, 60 Hz, PCG v1,
    // seed 42, one frame, and the 19-byte environment for g/b/a with no saves.
    try std.testing.expectEqualSlices(u8, &.{
        'U', 'P', 'R', '4', 60, 0, 0,   0, 1,   0, 0, 0,
        42,  0,   0,   0,   0,  0, 0,   0, 1,   0, 0, 0,
        19,  0,   0,   0,   1,  0, 0,   0, 'g', 1, 0, 0,
        0,   'b', 1,   0,   0,  0, 'a', 0, 0,   0, 0,
    }, encoded[0 .. header_bytes_v4 + 19]);
    for (0..encoded.len) |length| {
        if (parse(allocator, encoded[0..length])) |value| {
            var unexpected = value;
            unexpected.deinit(allocator);
            return error.ExpectedInvalidReplay;
        } else |_| {}
    }
    const environment_len = std.mem.readInt(u32, encoded[24..28], .little);
    std.mem.writeInt(u32, encoded[24..28], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.ReplayEnvironmentTooLarge, parse(allocator, encoded));
    std.mem.writeInt(u32, encoded[24..28], environment_len, .little);
    // Three one-byte identity fields, followed by the save count.
    std.mem.writeInt(u32, encoded[header_bytes_v4 + 15 ..][0..4], Replay.Environment.max_saves + 1, .little);
    try std.testing.expectError(error.ReplayEnvironmentTooLarge, parse(allocator, encoded));
    // Legacy run lengths must fail without overflowing in safe build modes.
    var legacy_buffer: [80]u8 = undefined;
    const legacy = try std.fmt.bufPrint(&legacy_buffer, "UPR1 60\n1 0\n{d} 0\n", .{std.math.maxInt(usize)});
    try std.testing.expectError(error.InvalidReplay, parse(allocator, legacy));
}

test "session capture rejects duplicate keys and enforces the total save budget" {
    const allocator = std.testing.allocator;
    var saves: @import("test_support.zig").InMemorySaveStore = undefined;
    saves.init(allocator);
    defer saves.deinit();
    const identity = Replay.Environment.Identity{ .game = "g", .build = "b", .assets = "a" };
    try std.testing.expectError(error.DuplicateReplaySave, Recorder.initSession(allocator, 60, 42, .{
        .identity = identity,
        .save_data = saves.capability(),
        .save_keys = &.{ "slot", "slot" },
    }));
    try std.testing.expectError(error.SaveDataUnavailable, Recorder.initSession(allocator, 60, 42, .{
        .identity = identity,
        .save_keys = &.{"slot"},
    }));
    const full = try allocator.alloc(u8, Replay.Environment.max_save_bytes);
    defer allocator.free(full);
    @memset(full, 5);
    try saves.capability().write("full", full);
    try saves.capability().write("extra", "x");
    try std.testing.expectError(error.ReplayEnvironmentTooLarge, Recorder.initSession(allocator, 60, 42, .{
        .identity = identity,
        .save_data = saves.capability(),
        .save_keys = &.{ "full", "extra" },
    }));
}
