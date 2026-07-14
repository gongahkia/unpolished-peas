const std = @import("std");

pub const max_frames: usize = 100_000;
pub const Frame = struct { buttons: u8 };
pub const Replay = struct { // owns parsed frame storage returned by parse; call deinit once.
    fixed_hz: u32,
    frames: []Frame,

    pub fn deinit(self: *Replay, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Replay {
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    const header = lines.next() orelse return error.InvalidReplay;
    var fields = std.mem.tokenizeScalar(u8, header, ' ');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidReplay, "UPR1")) return error.InvalidReplay;
    const fixed_hz = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidReplay, 10);
    if (fixed_hz == 0 or fields.next() != null) return error.InvalidReplay;
    var output = std.ArrayListUnmanaged(Frame){};
    errdefer output.deinit(allocator);
    while (lines.next()) |line| {
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
