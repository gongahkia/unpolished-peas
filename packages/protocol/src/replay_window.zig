const std = @import("std");

pub const max_replay_window_packets: usize = 64;
pub const ReplayWindowError = error{InvalidConfiguration};
pub const ReplayClassification = enum { accepted, duplicate, too_old };

pub const ReplayWindowConfig = struct {
    window_size: usize = max_replay_window_packets,
};

pub const ReplayWindow = struct {
    window_size: usize,
    latest: ?u64 = null,
    received: u64 = 0,

    pub fn init(config: ReplayWindowConfig) ReplayWindowError!ReplayWindow {
        if (config.window_size == 0 or config.window_size > max_replay_window_packets) return error.InvalidConfiguration;
        return .{ .window_size = config.window_size };
    }

    pub fn observe(self: *ReplayWindow, sequence: u64) ReplayClassification {
        const latest = self.latest orelse {
            self.latest = sequence;
            self.received = 1;
            return .accepted;
        };
        if (sequence > latest) {
            const distance = sequence - latest;
            self.latest = sequence;
            self.received = if (distance >= self.window_size) 1 else ((self.received << @intCast(distance)) | 1) & self.mask();
            return .accepted;
        }
        const distance = latest - sequence;
        if (distance >= self.window_size) return .too_old;
        const bit = @as(u64, 1) << @intCast(distance);
        if (self.received & bit != 0) return .duplicate;
        self.received |= bit;
        return .accepted;
    }

    pub fn reset(self: *ReplayWindow) void {
        self.latest = null;
        self.received = 0;
    }

    fn mask(self: ReplayWindow) u64 {
        if (self.window_size == max_replay_window_packets) return std.math.maxInt(u64);
        return (@as(u64, 1) << @intCast(self.window_size)) - 1;
    }
};

test "replay windows accept bounded out-of-order packets exactly once" {
    var window = try ReplayWindow.init(.{ .window_size = 4 });
    try std.testing.expectEqual(ReplayClassification.accepted, window.observe(10));
    try std.testing.expectEqual(ReplayClassification.duplicate, window.observe(10));
    try std.testing.expectEqual(ReplayClassification.accepted, window.observe(12));
    try std.testing.expectEqual(ReplayClassification.accepted, window.observe(11));
    try std.testing.expectEqual(ReplayClassification.duplicate, window.observe(11));
    try std.testing.expectEqual(ReplayClassification.too_old, window.observe(8));
    try std.testing.expectEqual(ReplayClassification.accepted, window.observe(16));
    try std.testing.expectEqual(ReplayClassification.too_old, window.observe(12));
    window.reset();
    try std.testing.expectEqual(ReplayClassification.accepted, window.observe(0));
}

test "replay windows enforce explicit bounded configuration" {
    try std.testing.expectError(error.InvalidConfiguration, ReplayWindow.init(.{ .window_size = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, ReplayWindow.init(.{ .window_size = max_replay_window_packets + 1 }));
}
