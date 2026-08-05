const std = @import("std");
const core = @import("minna-san-core");

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

pub const max_network_messages: usize = 64;
pub const DeterministicNetworkError = error{ InvalidConfiguration, MessageTooLarge, QueueFull, InjectedFailure };

pub const DeterministicNetworkConfig = struct {
    maximum_messages: usize,
    maximum_message_bytes: usize,
};

pub const DeterministicNetworkMessage = struct {
    sequence: u64,
    payload: core.BorrowedBuffer,
};

pub const DeterministicNetwork = struct {
    config: DeterministicNetworkConfig,
    messages: [max_network_messages]DeterministicNetworkMessage = undefined,
    first: usize = 0,
    count: usize = 0,
    next_sequence: u64 = 0,
    reject_next: bool = false,

    pub fn init(config: DeterministicNetworkConfig) DeterministicNetworkError!DeterministicNetwork {
        if (config.maximum_messages == 0 or config.maximum_messages > max_network_messages or config.maximum_message_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn fail_next(self: *DeterministicNetwork) void {
        self.reject_next = true;
    }

    pub fn send(self: *DeterministicNetwork, payload: []const u8) DeterministicNetworkError!void {
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

    pub fn receive(self: *DeterministicNetwork) ?DeterministicNetworkMessage {
        if (self.count == 0) return null;
        const message = self.messages[self.first];
        self.first = (self.first + 1) % self.config.maximum_messages;
        self.count -= 1;
        return message;
    }
};

pub const ProcessFixtureError = error{ InvalidConfiguration, InvalidCommand, InvocationLimitReached };

pub const ProcessFixtureConfig = struct {
    maximum_invocations: usize,
    exit_code: u8 = 0,
    stdout: []const u8 = "",
};

pub const ProcessFixtureResult = struct {
    exit_code: u8,
    stdout: []const u8,
};

pub const ProcessFixture = struct {
    config: ProcessFixtureConfig,
    invocations: usize = 0,

    pub fn init(config: ProcessFixtureConfig) ProcessFixtureError!ProcessFixture {
        if (config.maximum_invocations == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn run(self: *ProcessFixture, command: []const u8) ProcessFixtureError!ProcessFixtureResult {
        if (command.len == 0) return error.InvalidCommand;
        if (self.invocations == self.config.maximum_invocations) return error.InvocationLimitReached;
        self.invocations += 1;
        return .{ .exit_code = self.config.exit_code, .stdout = self.config.stdout };
    }
};

pub const CertificateFixtureError = error{ InvalidConfiguration, NotYetValid, Expired };

pub const CertificateFixture = struct {
    subject: []const u8,
    not_before_ns: core.TimeNs,
    not_after_ns: core.TimeNs,

    pub fn init(subject: []const u8, not_before_ns: core.TimeNs, not_after_ns: core.TimeNs) CertificateFixtureError!CertificateFixture {
        if (subject.len == 0 or not_after_ns <= not_before_ns) return error.InvalidConfiguration;
        return .{ .subject = subject, .not_before_ns = not_before_ns, .not_after_ns = not_after_ns };
    }

    pub fn validateAt(self: CertificateFixture, now_ns: core.TimeNs) CertificateFixtureError!void {
        if (now_ns < self.not_before_ns) return error.NotYetValid;
        if (now_ns >= self.not_after_ns) return error.Expired;
    }

    pub fn fingerprint(self: CertificateFixture) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.subject, &digest, .{});
        return digest;
    }
};

pub const DatabaseFixtureError = error{ InvalidConfiguration, InvalidQuery, Unavailable, QueryLimitReached };

pub const DatabaseFixtureConfig = struct {
    maximum_queries: usize,
    response: []const u8 = "1",
};

pub const DatabaseFixture = struct {
    config: DatabaseFixtureConfig,
    available: bool = true,
    queries: usize = 0,

    pub fn init(config: DatabaseFixtureConfig) DatabaseFixtureError!DatabaseFixture {
        if (config.maximum_queries == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn setAvailable(self: *DatabaseFixture, available: bool) void {
        self.available = available;
    }

    pub fn query(self: *DatabaseFixture, statement: []const u8) DatabaseFixtureError![]const u8 {
        if (statement.len == 0) return error.InvalidQuery;
        if (!self.available) return error.Unavailable;
        if (self.queries == self.config.maximum_queries) return error.QueryLimitReached;
        self.queries += 1;
        return self.config.response;
    }
};

test "bounded support fixtures provide deterministic process network certificate and database behavior" {
    var clock = DeterministicClock.init(4);
    try clock.advance(6);
    var network = try DeterministicNetwork.init(.{ .maximum_messages = 1, .maximum_message_bytes = 2 });
    try network.send("ok");
    try std.testing.expectEqual(@as(u64, 0), network.receive().?.sequence);
    var process = try ProcessFixture.init(.{ .maximum_invocations = 1, .stdout = "ready" });
    try std.testing.expectEqualStrings("ready", (try process.run("fixture")).stdout);
    const certificate = try CertificateFixture.init("fixture", 0, 11);
    try certificate.validateAt(clock.now());
    var database = try DatabaseFixture.init(.{ .maximum_queries = 1 });
    try std.testing.expectEqualStrings("1", try database.query("SELECT 1"));
}

test "bounded support fixtures reject invalid and order-dependent states" {
    var clock = DeterministicClock.init(std.math.maxInt(core.TimeNs));
    try std.testing.expectError(error.TimeOverflow, clock.advance(1));
    var network = try DeterministicNetwork.init(.{ .maximum_messages = 1, .maximum_message_bytes = 1 });
    network.fail_next();
    try std.testing.expectError(error.InjectedFailure, network.send("a"));
    try network.send("a");
    try std.testing.expectError(error.QueueFull, network.send("b"));
    var process = try ProcessFixture.init(.{ .maximum_invocations = 1 });
    _ = try process.run("fixture");
    try std.testing.expectError(error.InvocationLimitReached, process.run("fixture"));
    const certificate = try CertificateFixture.init("fixture", 1, 2);
    try std.testing.expectError(error.NotYetValid, certificate.validateAt(0));
    try std.testing.expectError(error.Expired, certificate.validateAt(2));
    var database = try DatabaseFixture.init(.{ .maximum_queries = 1 });
    database.setAvailable(false);
    try std.testing.expectError(error.Unavailable, database.query("SELECT 1"));
}
