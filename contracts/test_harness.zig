const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");

pub const DeterministicClock = struct {
    manual: core.ManualClock,

    pub fn init(now_ns: core.TimeNs) DeterministicClock {
        return .{ .manual = core.ManualClock.init(now_ns) };
    }

    pub fn clock(self: *DeterministicClock) core.Clock {
        return self.manual.clock();
    }

    pub fn now(self: *const DeterministicClock) core.TimeNs {
        return self.manual.now_ns;
    }

    pub fn advance(self: *DeterministicClock, delta_ns: core.TimeNs) core.ClockError!void {
        try self.manual.advance(delta_ns);
    }
};

pub const FixedAllocatorFixture = struct {
    fixed: std.heap.FixedBufferAllocator,

    pub fn init(storage: []u8) FixedAllocatorFixture {
        return .{ .fixed = std.heap.FixedBufferAllocator.init(storage) };
    }

    pub fn allocator(self: *FixedAllocatorFixture) std.mem.Allocator {
        return self.fixed.allocator();
    }
};

pub const max_transport_messages: usize = 64;
pub const DeterministicTransportError = error{
    InvalidConfiguration,
    MessageTooLarge,
    QueueFull,
    InjectedFailure,
};

pub const DeterministicTransportConfig = struct {
    maximum_messages: usize,
    maximum_message_bytes: usize,
};

pub const DeterministicTransportMessage = struct {
    sequence: u64,
    payload: core.BorrowedBuffer,
};

pub const DeterministicTransport = struct {
    config: DeterministicTransportConfig,
    messages: [max_transport_messages]DeterministicTransportMessage = undefined,
    first: usize = 0,
    count: usize = 0,
    next_sequence: u64 = 0,
    reject_next: bool = false,

    pub fn init(config: DeterministicTransportConfig) DeterministicTransportError!DeterministicTransport {
        if (config.maximum_messages == 0 or config.maximum_messages > max_transport_messages or config.maximum_message_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn fail_next(self: *DeterministicTransport) void {
        self.reject_next = true;
    }

    pub fn send(self: *DeterministicTransport, payload: []const u8) DeterministicTransportError!void {
        if (self.reject_next) {
            self.reject_next = false;
            return error.InjectedFailure;
        }
        if (payload.len > self.config.maximum_message_bytes) return error.MessageTooLarge;
        if (self.count == self.config.maximum_messages) return error.QueueFull;
        const index = (self.first + self.count) % self.config.maximum_messages;
        self.messages[index] = .{ .sequence = self.next_sequence, .payload = .init(payload) };
        self.next_sequence +%= 1;
        self.count += 1;
    }

    pub fn receive(self: *DeterministicTransport) ?DeterministicTransportMessage {
        if (self.count == 0) return null;
        const message = self.messages[self.first];
        self.first = (self.first + 1) % self.config.maximum_messages;
        self.count -= 1;
        return message;
    }
};

pub fn deterministic_identity(seed: u8) protocol.PublicKeyAuthenticationError!protocol.PublicKeyIdentity {
    return protocol.PublicKeyIdentity.init([_]u8{seed} ** std.crypto.sign.Ed25519.KeyPair.seed_length);
}

pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    try std.testing.expectEqualSlices(T, expected, actual);
}

pub fn expectError(expected_error: anyerror, actual: anytype) !void {
    try std.testing.expectError(expected_error, actual);
}

test "test harness fixtures preserve deterministic success paths" {
    var clock = DeterministicClock.init(4);
    try clock.advance(6);
    try std.testing.expectEqual(@as(core.TimeNs, 10), clock.clock().now());
    var storage: [2]u8 = undefined;
    var allocation = FixedAllocatorFixture.init(storage[0..]);
    const bytes = try allocation.allocator().alloc(u8, 2);
    @memset(bytes, 0);
    try expectEqualSlices(u8, &.{ 0, 0 }, bytes);
    var transport = try DeterministicTransport.init(.{ .maximum_messages = 2, .maximum_message_bytes = 2 });
    try transport.send("a");
    try transport.send("b");
    const first = transport.receive().?;
    const second = transport.receive().?;
    try std.testing.expectEqual(@as(u64, 0), first.sequence);
    try std.testing.expectEqual(@as(u64, 1), second.sequence);
    try expectEqualSlices(u8, "a", first.payload.bytes);
    try expectEqualSlices(u8, "b", second.payload.bytes);
    var first_identity = try deterministic_identity(3);
    defer first_identity.clear();
    var second_identity = try deterministic_identity(3);
    defer second_identity.clear();
    try std.testing.expectEqual(try first_identity.public_key(), try second_identity.public_key());
}

test "test harness fixtures preserve deterministic failure paths" {
    var clock = DeterministicClock.init(std.math.maxInt(core.TimeNs));
    try expectError(error.TimeOverflow, clock.advance(1));
    var storage: [1]u8 = undefined;
    var allocation = FixedAllocatorFixture.init(storage[0..]);
    try expectError(error.OutOfMemory, allocation.allocator().alloc(u8, 2));
    try expectError(error.InvalidConfiguration, DeterministicTransport.init(.{ .maximum_messages = 0, .maximum_message_bytes = 1 }));
    var transport = try DeterministicTransport.init(.{ .maximum_messages = 1, .maximum_message_bytes = 1 });
    transport.fail_next();
    try expectError(error.InjectedFailure, transport.send("a"));
    try transport.send("a");
    try expectError(error.QueueFull, transport.send("b"));
    try expectError(error.MessageTooLarge, transport.send("xx"));
}
