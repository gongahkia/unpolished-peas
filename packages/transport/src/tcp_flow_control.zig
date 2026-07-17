const std = @import("std");

pub const TcpFlowControlError = error{ InvalidConfiguration, WriteQueueFull, WriteCompletionMismatch };

pub const TcpFlowControlConfig = struct {
    maximum_queued_bytes: usize,
};

pub const TcpFlowController = struct {
    maximum_queued_bytes: usize,
    queued_bytes: usize = 0,
    reads_paused: bool = false,

    pub fn init(config: TcpFlowControlConfig) TcpFlowControlError!TcpFlowController {
        if (config.maximum_queued_bytes == 0) return error.InvalidConfiguration;
        return .{ .maximum_queued_bytes = config.maximum_queued_bytes };
    }

    pub fn available_write_bytes(self: TcpFlowController) usize {
        return self.maximum_queued_bytes - self.queued_bytes;
    }

    pub fn reserve_write(self: *TcpFlowController, bytes: usize) TcpFlowControlError!void {
        if (bytes > self.available_write_bytes()) return error.WriteQueueFull;
        self.queued_bytes += bytes;
    }

    pub fn complete_write(self: *TcpFlowController, bytes: usize) TcpFlowControlError!void {
        if (bytes > self.queued_bytes) return error.WriteCompletionMismatch;
        self.queued_bytes -= bytes;
    }

    pub fn pause_reads(self: *TcpFlowController) void {
        self.reads_paused = true;
    }

    pub fn resume_reads(self: *TcpFlowController) void {
        self.reads_paused = false;
    }
};

test "TCP flow control bounds write reservations and releases capacity" {
    var controller = try TcpFlowController.init(.{ .maximum_queued_bytes = 8 });
    try controller.reserve_write(5);
    try std.testing.expectEqual(@as(usize, 3), controller.available_write_bytes());
    try std.testing.expectError(error.WriteQueueFull, controller.reserve_write(4));
    try controller.complete_write(2);
    try std.testing.expectEqual(@as(usize, 5), controller.available_write_bytes());
    try std.testing.expectError(error.WriteCompletionMismatch, controller.complete_write(7));
}

test "TCP flow control exposes caller-controlled read pausing" {
    var controller = try TcpFlowController.init(.{ .maximum_queued_bytes = 1 });
    try std.testing.expect(!controller.reads_paused);
    controller.pause_reads();
    try std.testing.expect(controller.reads_paused);
    controller.resume_reads();
    try std.testing.expect(!controller.reads_paused);
    try std.testing.expectError(error.InvalidConfiguration, TcpFlowController.init(.{ .maximum_queued_bytes = 0 }));
}
