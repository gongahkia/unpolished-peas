const std = @import("std");
const transport = @import("minna-san-transport");
const delivery = @import("channel_delivery.zig");
const tls_alpn = @import("tls_alpn.zig");

pub const max_quic_session_tickets: usize = 64;
pub const max_quic_session_ticket_bytes: usize = 16 * 1024;

pub const QuicSessionTicketKey = struct {
    server_name: []const u8,
    alpn: []const u8,

    pub fn validate(self: QuicSessionTicketKey) error{InvalidTicketKey}!void {
        if (self.server_name.len == 0 or self.server_name.len > transport.max_endpoint_hostname_bytes or self.alpn.len == 0 or self.alpn.len > tls_alpn.max_tls_alpn_protocol_bytes) return error.InvalidTicketKey;
    }
};

pub const QuicSessionTicketStoreConfig = struct {
    maximum_tickets: usize = 8,
    maximum_ticket_bytes: usize = max_quic_session_ticket_bytes,

    pub fn validate(self: QuicSessionTicketStoreConfig) error{InvalidConfiguration}!void {
        if (self.maximum_tickets == 0 or self.maximum_tickets > max_quic_session_tickets or self.maximum_ticket_bytes == 0 or self.maximum_ticket_bytes > max_quic_session_ticket_bytes) return error.InvalidConfiguration;
    }
};

pub const QuicSessionTicketStoreError = std.mem.Allocator.Error || error{ InvalidConfiguration, InvalidTicketKey, TicketTooLarge, TicketCapacityExceeded };

const TicketEntry = struct {
    server_name: []u8,
    alpn: []u8,
    ticket: []u8,

    fn deinit(self: *TicketEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.server_name);
        allocator.free(self.alpn);
        std.crypto.secureZero(u8, self.ticket);
        allocator.free(self.ticket);
        self.* = undefined;
    }
};

pub const QuicSessionTicketStore = struct {
    allocator: std.mem.Allocator,
    config: QuicSessionTicketStoreConfig,
    entries: std.ArrayListUnmanaged(TicketEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: QuicSessionTicketStoreConfig) QuicSessionTicketStoreError!QuicSessionTicketStore {
        try config.validate();
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *QuicSessionTicketStore) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn store(self: *QuicSessionTicketStore, key: QuicSessionTicketKey, ticket_bytes: []const u8) QuicSessionTicketStoreError!void {
        try key.validate();
        if (ticket_bytes.len == 0 or ticket_bytes.len > self.config.maximum_ticket_bytes) return error.TicketTooLarge;
        if (self.find(key)) |entry| {
            const replacement = try self.allocator.dupe(u8, ticket_bytes);
            std.crypto.secureZero(u8, entry.ticket);
            self.allocator.free(entry.ticket);
            entry.ticket = replacement;
            return;
        }
        if (self.entries.items.len == self.config.maximum_tickets) return error.TicketCapacityExceeded;
        const server_name = try self.allocator.dupe(u8, key.server_name);
        errdefer self.allocator.free(server_name);
        const alpn = try self.allocator.dupe(u8, key.alpn);
        errdefer self.allocator.free(alpn);
        const ticket_copy = try self.allocator.dupe(u8, ticket_bytes);
        errdefer self.allocator.free(ticket_copy);
        try self.entries.append(self.allocator, .{ .server_name = server_name, .alpn = alpn, .ticket = ticket_copy });
    }

    pub fn ticket(self: *const QuicSessionTicketStore, key: QuicSessionTicketKey) ?[]const u8 {
        key.validate() catch return null;
        return if (self.find(key)) |entry| entry.ticket else null;
    }

    pub fn remove(self: *QuicSessionTicketStore, key: QuicSessionTicketKey) bool {
        key.validate() catch return false;
        for (self.entries.items, 0..) |entry, index| {
            if (!matches(entry, key)) continue;
            var removed = self.entries.orderedRemove(index);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn count(self: *const QuicSessionTicketStore) usize {
        return self.entries.items.len;
    }

    fn find(self: *const QuicSessionTicketStore, key: QuicSessionTicketKey) ?*TicketEntry {
        for (self.entries.items) |*entry| if (matches(entry.*, key)) return entry;
        return null;
    }
};

pub const QuicEarlyDataState = enum {
    unavailable,
    eligible,
    one_rtt,
};

pub const QuicSendMode = enum {
    one_rtt_only,
    zero_rtt_permitted,
};

pub const QuicEarlyDataRejection = enum {
    not_attempted,
    retry_at_one_rtt,
};

pub const QuicEarlyDataPolicy = struct {
    ticket_store: *const QuicSessionTicketStore,
    key: QuicSessionTicketKey,
    state: QuicEarlyDataState,

    pub fn init(ticket_store: *const QuicSessionTicketStore, key: QuicSessionTicketKey, allow_early_data: bool) error{InvalidTicketKey}!QuicEarlyDataPolicy {
        try key.validate();
        return .{ .ticket_store = ticket_store, .key = key, .state = if (ticket_store.ticket(key) != null and allow_early_data) .eligible else if (ticket_store.ticket(key) != null) .one_rtt else .unavailable };
    }

    pub fn ticket(self: *const QuicEarlyDataPolicy) ?[]const u8 {
        return self.ticket_store.ticket(self.key);
    }

    pub fn sendMode(self: *const QuicEarlyDataPolicy, descriptor: delivery.ChannelDescriptor) QuicSendMode {
        return if (self.state == .eligible and descriptor.replay_safety == .replay_safe) .zero_rtt_permitted else .one_rtt_only;
    }

    pub fn rejectEarlyData(self: *QuicEarlyDataPolicy) QuicEarlyDataRejection {
        if (self.state != .eligible) return .not_attempted;
        self.state = .one_rtt;
        return .retry_at_one_rtt;
    }
};

fn matches(entry: TicketEntry, key: QuicSessionTicketKey) bool {
    return std.mem.eql(u8, entry.server_name, key.server_name) and std.mem.eql(u8, entry.alpn, key.alpn);
}

test "QUIC ticket stores copy bounded tickets by server and ALPN" {
    var store = try QuicSessionTicketStore.init(std.testing.allocator, .{ .maximum_tickets = 1, .maximum_ticket_bytes = 8 });
    defer store.deinit();
    const key = QuicSessionTicketKey{ .server_name = "example.test", .alpn = "h3" };
    var source = [_]u8{ 1, 2, 3 };
    try store.store(key, &source);
    source[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, store.ticket(key).?);
    try store.store(key, "next");
    try std.testing.expectEqualSlices(u8, "next", store.ticket(key).?);
    try std.testing.expectError(error.TicketCapacityExceeded, store.store(.{ .server_name = "other.test", .alpn = "h3" }, "ticket"));
    try std.testing.expectError(error.TicketTooLarge, store.store(key, "oversized"));
    try std.testing.expect(store.remove(key));
    try std.testing.expect(store.ticket(key) == null);
}

test "QUIC early-data policies keep replay-sensitive channels at one RTT and retry rejected data" {
    var store = try QuicSessionTicketStore.init(std.testing.allocator, .{});
    defer store.deinit();
    const key = QuicSessionTicketKey{ .server_name = "example.test", .alpn = "h3" };
    try store.store(key, "ticket");
    var policy = try QuicEarlyDataPolicy.init(&store, key, true);
    const replay_safe = delivery.ChannelDescriptor{ .delivery = .stream, .maximum_payload_bytes = 16 };
    const replay_sensitive = delivery.ChannelDescriptor{ .delivery = .stream, .maximum_payload_bytes = 16, .replay_safety = .replay_sensitive };
    try std.testing.expectEqual(QuicEarlyDataState.eligible, policy.state);
    try std.testing.expectEqual(QuicSendMode.zero_rtt_permitted, policy.sendMode(replay_safe));
    try std.testing.expectEqual(QuicSendMode.one_rtt_only, policy.sendMode(replay_sensitive));
    try std.testing.expectEqual(QuicEarlyDataRejection.retry_at_one_rtt, policy.rejectEarlyData());
    try std.testing.expectEqual(QuicEarlyDataState.one_rtt, policy.state);
    try std.testing.expectEqual(QuicSendMode.one_rtt_only, policy.sendMode(replay_safe));
    try std.testing.expectEqual(QuicEarlyDataRejection.not_attempted, policy.rejectEarlyData());
}
