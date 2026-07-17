const std = @import("std");

pub const TransportConnectionState = enum {
    resolving,
    connecting,
    connected,
    closing,
    failed,
    closed,
};

pub const TransportConnectionStateError = error{InvalidTransition};

pub const TransportConnectionTracker = struct {
    state: TransportConnectionState = .resolving,

    pub fn transition(self: *TransportConnectionTracker, next: TransportConnectionState) TransportConnectionStateError!void {
        if (!is_transition_allowed(self.state, next)) return error.InvalidTransition;
        self.state = next;
    }

    pub fn fail(self: *TransportConnectionTracker) TransportConnectionStateError!void {
        try self.transition(.failed);
    }

    pub fn begin_close(self: *TransportConnectionTracker) TransportConnectionStateError!void {
        try self.transition(.closing);
    }

    pub fn finish_close(self: *TransportConnectionTracker) TransportConnectionStateError!void {
        try self.transition(.closed);
    }
};

pub fn is_transition_allowed(current: TransportConnectionState, next: TransportConnectionState) bool {
    return switch (current) {
        .resolving => next == .connecting or next == .failed or next == .closing,
        .connecting => next == .connected or next == .failed or next == .closing,
        .connected => next == .closing or next == .failed,
        .closing => next == .closed or next == .failed,
        .failed => next == .closed,
        .closed => false,
    };
}

test "transport-neutral connection tracking preserves normal lifecycle states" {
    var tracker = TransportConnectionTracker{};
    try std.testing.expectEqual(TransportConnectionState.resolving, tracker.state);
    try tracker.transition(.connecting);
    try tracker.transition(.connected);
    try tracker.begin_close();
    try tracker.finish_close();
    try std.testing.expectEqual(TransportConnectionState.closed, tracker.state);
}

test "transport-neutral connection tracking preserves failure terminal paths" {
    var tracker = TransportConnectionTracker{};
    try tracker.fail();
    try std.testing.expectEqual(TransportConnectionState.failed, tracker.state);
    try tracker.finish_close();
    try std.testing.expectEqual(TransportConnectionState.closed, tracker.state);
    try std.testing.expectError(error.InvalidTransition, tracker.transition(.connected));
}
