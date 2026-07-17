const std = @import("std");

pub const RouteId = u64;

pub const CongestionFeedback = struct {
    acknowledged_bytes: usize = 0,
    lost_bytes: usize = 0,
    rtt_ns: ?u64 = null,
};

pub const CongestionController = struct {
    context: *anyopaque,
    send_budget_fn: *const fn (*anyopaque, RouteId) usize,
    sent_fn: *const fn (*anyopaque, RouteId, usize, u64) void,
    feedback_fn: *const fn (*anyopaque, RouteId, CongestionFeedback, u64) void,
    reset_fn: *const fn (*anyopaque, RouteId) void,

    pub fn send_budget(self: CongestionController, route: RouteId) usize {
        return self.send_budget_fn(self.context, route);
    }

    pub fn on_sent(self: CongestionController, route: RouteId, bytes: usize, now_ns: u64) void {
        self.sent_fn(self.context, route, bytes, now_ns);
    }

    pub fn on_feedback(self: CongestionController, route: RouteId, feedback: CongestionFeedback, now_ns: u64) void {
        self.feedback_fn(self.context, route, feedback, now_ns);
    }

    pub fn reset(self: CongestionController, route: RouteId) void {
        self.reset_fn(self.context, route);
    }
};

test "congestion controller contract preserves route lifecycle callbacks" {
    const Stub = struct {
        budget: usize = 100,
        sent: usize = 0,
        acknowledged: usize = 0,
        lost: usize = 0,
        resets: usize = 0,

        fn controller(self: *@This()) CongestionController {
            return .{ .context = self, .send_budget_fn = budget_fn, .sent_fn = sent_fn, .feedback_fn = feedback_fn, .reset_fn = reset_fn };
        }

        fn budget_fn(context: *anyopaque, _: RouteId) usize {
            return (@as(*@This(), @ptrCast(@alignCast(context))).budget);
        }

        fn sent_fn(context: *anyopaque, _: RouteId, bytes: usize, _: u64) void {
            @as(*@This(), @ptrCast(@alignCast(context))).sent += bytes;
        }

        fn feedback_fn(context: *anyopaque, _: RouteId, feedback: CongestionFeedback, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.acknowledged += feedback.acknowledged_bytes;
            self.lost += feedback.lost_bytes;
        }

        fn reset_fn(context: *anyopaque, _: RouteId) void {
            @as(*@This(), @ptrCast(@alignCast(context))).resets += 1;
        }
    };
    var stub = Stub{};
    const controller = stub.controller();
    try std.testing.expectEqual(@as(usize, 100), controller.send_budget(1));
    controller.on_sent(1, 10, 0);
    controller.on_feedback(1, .{ .acknowledged_bytes = 8, .lost_bytes = 2, .rtt_ns = 1 }, 1);
    controller.reset(1);
    try std.testing.expectEqual(@as(usize, 10), stub.sent);
    try std.testing.expectEqual(@as(usize, 8), stub.acknowledged);
    try std.testing.expectEqual(@as(usize, 2), stub.lost);
    try std.testing.expectEqual(@as(usize, 1), stub.resets);
}
