const std = @import("std");

pub const SessionState = enum(u32) { idle, establishing, ready, draining, closed };
pub const SessionTransition = enum(u32) { begin_establishing, mark_ready, begin_draining, close };
pub const SessionLifecycleError = error{InvalidTransition};

pub const SessionLifecycle = struct {
    state: SessionState = .idle,

    pub fn can_transition(state: SessionState, action: SessionTransition) bool {
        return switch (state) {
            .idle => action == .begin_establishing,
            .establishing => action == .mark_ready or action == .begin_draining,
            .ready => action == .begin_draining,
            .draining => action == .close,
            .closed => false,
        };
    }

    pub fn transition(self: *SessionLifecycle, action: SessionTransition) SessionLifecycleError!void {
        if (!can_transition(self.state, action)) return error.InvalidTransition;
        self.state = switch (action) {
            .begin_establishing => .establishing,
            .mark_ready => .ready,
            .begin_draining => .draining,
            .close => .closed,
        };
    }
};

test "session lifecycle transition matrix rejects every illegal transition" {
    const states = [_]SessionState{ .idle, .establishing, .ready, .draining, .closed };
    const transitions = [_]SessionTransition{ .begin_establishing, .mark_ready, .begin_draining, .close };
    for (states) |state| {
        for (transitions) |action| {
            var lifecycle = SessionLifecycle{ .state = state };
            if (SessionLifecycle.can_transition(state, action)) {
                try lifecycle.transition(action);
                try std.testing.expect(lifecycle.state != state);
            } else {
                try std.testing.expectError(error.InvalidTransition, lifecycle.transition(action));
                try std.testing.expectEqual(state, lifecycle.state);
            }
        }
    }
}

test "session lifecycle fuzz corpus preserves the transition table" {
    var prng = std.Random.DefaultPrng.init(0x18e9_73af_00d4_c1b5);
    const random = prng.random();
    var lifecycle = SessionLifecycle{};
    var iteration: usize = 0;
    while (iteration < 512) : (iteration += 1) {
        const action: SessionTransition = @enumFromInt(random.uintLessThan(u32, 4));
        const before = lifecycle.state;
        if (SessionLifecycle.can_transition(before, action)) {
            try lifecycle.transition(action);
        } else {
            try std.testing.expectError(error.InvalidTransition, lifecycle.transition(action));
            try std.testing.expectEqual(before, lifecycle.state);
        }
        if (lifecycle.state == .closed) lifecycle = .{};
    }
}
