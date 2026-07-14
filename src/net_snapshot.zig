const std = @import("std");

pub const max_state_bytes: usize = 1024;
pub const no_baseline: u32 = std.math.maxInt(u32);
pub const header_bytes: usize = 13;

const Kind = enum(u8) { full = 1, delta = 2 };

pub const Config = struct { history_limit: usize = 32 };
pub const Snapshot = struct { // owns encoded bytes returned by publish; call deinit with the publisher allocator.
    id: u32,
    bytes: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Publisher = struct { // owns retained baseline states allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    config: Config,
    next_id: u32 = 1,
    history: std.ArrayListUnmanaged(StoredState) = .{},

    const StoredState = struct { id: u32, bytes: []u8 };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Publisher {
        if (config.history_limit == 0) return error.InvalidSnapshotConfig;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Publisher) void {
        for (self.history.items) |state| self.allocator.free(state.bytes);
        self.history.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn publish(self: *Publisher, acknowledged_id: ?u32, state: []const u8) !Snapshot {
        if (state.len > max_state_bytes) return error.StateTooLarge;
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == no_baseline) self.next_id = 1;
        const baseline = if (acknowledged_id) |acknowledged| self.find(acknowledged) else null;
        var snapshot = if (baseline) |value| try self.encodeDelta(id, value, state) else try self.encodeFull(id, state);
        errdefer snapshot.deinit(self.allocator);
        try self.remember(id, state);
        return snapshot;
    }

    fn encodeFull(self: Publisher, id: u32, state: []const u8) !Snapshot {
        const bytes = try self.allocator.alloc(u8, header_bytes + state.len);
        encodeHeader(bytes[0..header_bytes], .full, id, no_baseline, @intCast(state.len), 0);
        @memcpy(bytes[header_bytes..], state);
        return .{ .id = id, .bytes = bytes };
    }

    fn encodeDelta(self: Publisher, id: u32, baseline: StoredState, state: []const u8) !Snapshot {
        var changes: usize = 0;
        for (state, 0..) |byte, index| {
            const previous = if (index < baseline.bytes.len) baseline.bytes[index] else 0;
            if (byte != previous) changes += 1;
        }
        const delta_len = header_bytes + changes * 3;
        if (delta_len >= header_bytes + state.len) return self.encodeFull(id, state);
        const bytes = try self.allocator.alloc(u8, delta_len);
        encodeHeader(bytes[0..header_bytes], .delta, id, baseline.id, @intCast(state.len), @intCast(changes));
        var at: usize = header_bytes;
        for (state, 0..) |byte, index| {
            const previous = if (index < baseline.bytes.len) baseline.bytes[index] else 0;
            if (byte == previous) continue;
            std.mem.writeInt(u16, bytes[at..][0..2], @intCast(index), .little);
            bytes[at + 2] = byte;
            at += 3;
        }
        return .{ .id = id, .bytes = bytes };
    }

    fn remember(self: *Publisher, id: u32, state: []const u8) !void {
        try self.history.append(self.allocator, .{ .id = id, .bytes = try self.allocator.dupe(u8, state) });
        if (self.history.items.len <= self.config.history_limit) return;
        const expired = self.history.orderedRemove(0);
        self.allocator.free(expired.bytes);
    }

    fn find(self: Publisher, id: u32) ?StoredState {
        for (self.history.items) |state| if (state.id == id) return state;
        return null;
    }
};

pub const Client = struct { // owns reconstructed snapshot history allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    config: Config,
    history: std.ArrayListUnmanaged(StoredState) = .{},
    current_id: ?u32 = null,
    recovery_required: bool = false,

    const StoredState = struct { id: u32, bytes: []u8 };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        if (config.history_limit == 0) return error.InvalidSnapshotConfig;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        self.reset();
        self.history.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Client) void {
        for (self.history.items) |stored| self.allocator.free(stored.bytes);
        self.history.clearRetainingCapacity();
        self.current_id = null;
        self.recovery_required = false;
    }

    pub fn apply(self: *Client, packet: []const u8) !void {
        const decoded = try decode(packet);
        if (self.find(decoded.id) != null) return;
        const rebuilt = switch (decoded.kind) {
            .full => try self.allocator.dupe(u8, decoded.payload),
            .delta => try self.applyDelta(decoded),
        };
        errdefer self.allocator.free(rebuilt);
        if (self.current_id == null or isAfter(decoded.id, self.current_id.?)) self.current_id = decoded.id;
        try self.history.append(self.allocator, .{ .id = decoded.id, .bytes = rebuilt });
        if (self.history.items.len > self.config.history_limit) {
            var expired_index: usize = 0;
            if (self.history.items[expired_index].id == self.current_id.?) expired_index = 1;
            const expired = self.history.orderedRemove(expired_index);
            self.allocator.free(expired.bytes);
        }
        self.recovery_required = false;
    }

    pub fn acknowledgement(self: Client) ?u32 {
        return self.current_id;
    }

    pub fn state(self: Client) ?[]const u8 {
        const id = self.current_id orelse return null;
        return (self.find(id) orelse return null).bytes;
    }

    fn applyDelta(self: *Client, decoded: Decoded) ![]u8 {
        const baseline = self.find(decoded.baseline_id) orelse {
            self.recovery_required = true;
            return error.MissingBaseline;
        };
        const rebuilt = try self.allocator.alloc(u8, decoded.state_len);
        errdefer self.allocator.free(rebuilt);
        @memset(rebuilt, 0);
        @memcpy(rebuilt[0..@min(rebuilt.len, baseline.bytes.len)], baseline.bytes[0..@min(rebuilt.len, baseline.bytes.len)]);
        var at: usize = 0;
        var previous_index: ?u16 = null;
        while (at < decoded.payload.len) : (at += 3) {
            const index = std.mem.readInt(u16, decoded.payload[at..][0..2], .little);
            if (index >= rebuilt.len or (previous_index != null and index <= previous_index.?)) return error.MalformedSnapshot;
            rebuilt[index] = decoded.payload[at + 2];
            previous_index = index;
        }
        return rebuilt;
    }

    fn find(self: Client, id: u32) ?StoredState {
        for (self.history.items) |stored| if (stored.id == id) return stored;
        return null;
    }
};

const Decoded = struct { kind: Kind, id: u32, baseline_id: u32, state_len: usize, payload: []const u8 };

fn encodeHeader(destination: []u8, kind: Kind, id: u32, baseline_id: u32, state_len: u16, changes: u16) void {
    destination[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, destination[1..5], id, .little);
    std.mem.writeInt(u32, destination[5..9], baseline_id, .little);
    std.mem.writeInt(u16, destination[9..11], state_len, .little);
    std.mem.writeInt(u16, destination[11..13], changes, .little);
}

fn decode(packet: []const u8) !Decoded {
    if (packet.len < header_bytes) return error.MalformedSnapshot;
    const kind = std.meta.intToEnum(Kind, packet[0]) catch return error.MalformedSnapshot;
    const id = std.mem.readInt(u32, packet[1..5], .little);
    const baseline_id = std.mem.readInt(u32, packet[5..9], .little);
    const state_len: usize = std.mem.readInt(u16, packet[9..11], .little);
    const changes: usize = std.mem.readInt(u16, packet[11..13], .little);
    if (id == no_baseline or state_len > max_state_bytes) return error.MalformedSnapshot;
    const payload = packet[header_bytes..];
    switch (kind) {
        .full => if (baseline_id != no_baseline or changes != 0 or payload.len != state_len) return error.MalformedSnapshot,
        .delta => if (baseline_id == no_baseline or payload.len != changes * 3) return error.MalformedSnapshot,
    }
    return .{ .kind = kind, .id = id, .baseline_id = baseline_id, .state_len = state_len, .payload = payload };
}

fn isAfter(id: u32, reference: u32) bool {
    return id != reference and @as(i32, @bitCast(id -% reference)) > 0;
}

test "snapshot client rebuilds the latest state across drops and reordering" {
    var publisher = try Publisher.init(std.testing.allocator, .{});
    defer publisher.deinit();
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var state_one = [_]u8{'a'} ** 64;
    var state_two = state_one;
    state_two[10] = 'b';
    var state_three = state_one;
    state_three[20] = 'c';
    var state_four = state_one;
    state_four[30] = 'd';
    var dropped_state = state_one;
    dropped_state[40] = 'e';

    var first = try publisher.publish(null, &state_one);
    defer first.deinit(std.testing.allocator);
    try client.apply(first.bytes);
    const first_acknowledgement = client.acknowledgement().?;
    var second = try publisher.publish(first_acknowledgement, &state_two);
    defer second.deinit(std.testing.allocator);
    var third = try publisher.publish(first_acknowledgement, &state_three);
    defer third.deinit(std.testing.allocator);
    var fourth = try publisher.publish(first_acknowledgement, &state_four);
    defer fourth.deinit(std.testing.allocator);
    var dropped = try publisher.publish(first_acknowledgement, &dropped_state);
    defer dropped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@intFromEnum(Kind.delta), second.bytes[0]);

    try client.apply(third.bytes);
    try client.apply(second.bytes);
    try std.testing.expectEqualSlices(u8, &state_three, client.state().?);
    try client.apply(fourth.bytes);
    try std.testing.expectEqualSlices(u8, &state_four, client.state().?);
    try std.testing.expectEqual(fourth.id, client.acknowledgement().?);
}

test "snapshot client requests a full recovery when its acknowledged baseline is absent" {
    var publisher = try Publisher.init(std.testing.allocator, .{});
    defer publisher.deinit();
    var synchronized = try Client.init(std.testing.allocator, .{});
    defer synchronized.deinit();
    var recovered = try Client.init(std.testing.allocator, .{});
    defer recovered.deinit();
    var initial = [_]u8{'a'} ** 64;
    var updated = initial;
    updated[0] = 'z';

    var first = try publisher.publish(null, &initial);
    defer first.deinit(std.testing.allocator);
    try synchronized.apply(first.bytes);
    var delta = try publisher.publish(synchronized.acknowledgement(), &updated);
    defer delta.deinit(std.testing.allocator);
    try synchronized.apply(delta.bytes);
    try std.testing.expectError(error.MissingBaseline, recovered.apply(delta.bytes));
    try std.testing.expect(recovered.recovery_required);
    var full = try publisher.publish(null, &updated);
    defer full.deinit(std.testing.allocator);
    try recovered.apply(full.bytes);
    try std.testing.expectEqualSlices(u8, &updated, recovered.state().?);
    try std.testing.expect(!recovered.recovery_required);
}
