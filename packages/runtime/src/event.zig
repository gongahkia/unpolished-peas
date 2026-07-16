const core = @import("minna-san-core");

pub const EventMode = enum {
    poll,
    managed,
    replay,
};

pub const EventOwnership = enum {
    borrowed,
    transferred,
};

pub const EventBuffer = union(EventOwnership) {
    borrowed: core.BorrowedBuffer,
    transferred: core.TransferredBuffer,

    pub fn deinit(self: *EventBuffer) void {
        switch (self.*) {
            .borrowed => {},
            .transferred => |*buffer| buffer.deinit(),
        }
        self.* = undefined;
    }
};

pub const MessageEvent = struct {
    buffer: EventBuffer,
};

pub const OverflowEvent = struct {
    dropped_count: u64,
};

pub const EventKind = enum {
    connected,
    disconnected,
    message,
    overflow,
};

pub const Event = union(EventKind) {
    connected: void,
    disconnected: void,
    message: MessageEvent,
    overflow: OverflowEvent,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .message => |*message| message.buffer.deinit(),
            else => {},
        }
        self.* = undefined;
    }
};

pub const EventEnvelope = struct {
    sequence: u64,
    mode: EventMode,
    event: Event,

    pub fn deinit(self: *EventEnvelope) void {
        self.event.deinit();
        self.* = undefined;
    }
};

pub const EventOrderError = error{OutOfOrderEvent};

pub const EventOrder = struct {
    next_sequence: u64 = 0,

    pub fn accept(self: *EventOrder, envelope: *const EventEnvelope) EventOrderError!void {
        if (envelope.sequence != self.next_sequence) return error.OutOfOrderEvent;
        self.next_sequence += 1;
    }
};

test "ordered events support every execution mode and overflow reporting" {
    var order = EventOrder{};
    var poll_event = EventEnvelope{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } };
    defer poll_event.deinit();
    try order.accept(&poll_event);
    var managed_event = EventEnvelope{ .sequence = 1, .mode = .managed, .event = .{ .overflow = .{ .dropped_count = 3 } } };
    defer managed_event.deinit();
    try order.accept(&managed_event);
    var replay_event = EventEnvelope{ .sequence = 2, .mode = .replay, .event = .{ .disconnected = {} } };
    defer replay_event.deinit();
    try order.accept(&replay_event);
}

test "event payload ownership and ordering violations are checked" {
    const transfer = core.TransferredBuffer.init(try core.OwnedBuffer.initCopy(@import("std").testing.allocator, "event"));
    var event = EventEnvelope{
        .sequence = 1,
        .mode = .poll,
        .event = .{ .message = .{ .buffer = .{ .transferred = transfer } } },
    };
    defer event.deinit();
    var order = EventOrder{};
    try @import("std").testing.expectError(error.OutOfOrderEvent, order.accept(&event));
}
