const std = @import("std");
const Vec2 = @import("math.zig").Vec2;
const transport = @import("net_transport.zig");

pub const max_command_bytes: usize = 256;
pub const max_reordered_commands: usize = 64;
const command_header_bytes: usize = 11;
const acknowledgement_bytes: usize = 9;
const Kind = enum(u8) { command = 1, acknowledgement = 2 };
const Acknowledgement = struct { tick: u32, sequence: u32 };

pub const InterpolationConfig = struct {
    delay_ms: u64 = 100,
    max_snapshots: usize = 32,
};
pub const TimedSnapshot = struct { tick: u32, received_at_ms: u64, position: Vec2 };

pub const Interpolator = struct { // owns ordered snapshot storage allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    config: InterpolationConfig,
    snapshots: std.ArrayListUnmanaged(TimedSnapshot) = .{},

    pub fn init(allocator: std.mem.Allocator, config: InterpolationConfig) !Interpolator {
        if (config.max_snapshots < 2) return error.InvalidInterpolationConfig;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Interpolator) void {
        self.snapshots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *Interpolator, snapshot: TimedSnapshot) !void {
        for (self.snapshots.items, 0..) |existing, index| {
            if (existing.tick != snapshot.tick) continue;
            self.snapshots.items[index] = snapshot;
            return;
        }
        var index = self.snapshots.items.len;
        while (index > 0 and isAfter(self.snapshots.items[index - 1].tick, snapshot.tick)) : (index -= 1) {}
        try self.snapshots.insert(self.allocator, index, snapshot);
        if (self.snapshots.items.len > self.config.max_snapshots) _ = self.snapshots.orderedRemove(0);
    }

    pub fn sample(self: Interpolator, now_ms: u64) ?Vec2 {
        if (self.snapshots.items.len == 0) return null;
        const target = now_ms -| self.config.delay_ms;
        if (target <= self.snapshots.items[0].received_at_ms) return self.snapshots.items[0].position;
        for (self.snapshots.items[1..], 1..) |after, index| {
            const before = self.snapshots.items[index - 1];
            if (target > after.received_at_ms) continue;
            const span = after.received_at_ms - before.received_at_ms;
            if (span == 0) return after.position;
            const alpha: f32 = @floatFromInt(target - before.received_at_ms);
            const denominator: f32 = @floatFromInt(span);
            return .{ .x = before.position.x + (after.position.x - before.position.x) * alpha / denominator, .y = before.position.y + (after.position.y - before.position.y) * alpha / denominator };
        }
        return self.snapshots.items[self.snapshots.items.len - 1].position;
    }
};

pub const InputCommand = struct { // owns encoded payload bytes; call deinit with the command owner allocator.
    tick: u32,
    sequence: u32,
    payload: []u8,

    pub fn deinit(self: *InputCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const CommandClient = struct { // owns pending commands allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    peer: transport.Peer,
    next_sequence: u32 = 0,
    last_server_tick: ?u32 = null,
    pending: std.ArrayListUnmanaged(InputCommand) = .{},

    pub fn init(allocator: std.mem.Allocator, peer: transport.Peer) CommandClient {
        return .{ .allocator = allocator, .peer = peer };
    }

    pub fn deinit(self: *CommandClient) void {
        for (self.pending.items) |*command| command.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn send(self: *CommandClient, net: transport.Transport, tick: u32, payload: []const u8) !void {
        if (payload.len > max_command_bytes) return error.CommandTooLarge;
        const sequence = self.next_sequence;
        self.next_sequence +%= 1;
        errdefer self.next_sequence -%= 1;
        const owned_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned_payload);
        try self.pending.append(self.allocator, .{ .tick = tick, .sequence = sequence, .payload = owned_payload });
        errdefer {
            self.pending.items[self.pending.items.len - 1].deinit(self.allocator);
            _ = self.pending.pop();
        }
        var bytes: [command_header_bytes + max_command_bytes]u8 = undefined;
        try net.send(self.peer, try encodeCommand(&bytes, .{ .tick = tick, .sequence = sequence, .payload = owned_payload }));
    }

    pub fn poll(self: *CommandClient, net: transport.Transport) !void {
        try net.poll();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (packet.from.id != self.peer.id) continue;
            const acknowledgement = decodeAcknowledgement(packet.bytes) catch continue;
            self.last_server_tick = acknowledgement.tick;
            self.acknowledge(acknowledgement.sequence);
        }
    }

    fn acknowledge(self: *CommandClient, sequence: u32) void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            if (isAfter(self.pending.items[index].sequence, sequence)) {
                index += 1;
                continue;
            }
            var command = self.pending.orderedRemove(index);
            command.deinit(self.allocator);
        }
    }
};

pub const CommandServer = struct { // owns reordered and delivered commands allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    peer: transport.Peer,
    expected_sequence: u32 = 0,
    last_applied: ?Acknowledgement = null,
    reordered: std.ArrayListUnmanaged(InputCommand) = .{},
    delivered: std.ArrayListUnmanaged(InputCommand) = .{},

    pub fn init(allocator: std.mem.Allocator, peer: transport.Peer) CommandServer {
        return .{ .allocator = allocator, .peer = peer };
    }

    pub fn deinit(self: *CommandServer) void {
        for (self.reordered.items) |*command| command.deinit(self.allocator);
        self.reordered.deinit(self.allocator);
        for (self.delivered.items) |*command| command.deinit(self.allocator);
        self.delivered.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn poll(self: *CommandServer, net: transport.Transport) !void {
        try net.poll();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (packet.from.id != self.peer.id) continue;
            var command = decodeCommand(self.allocator, packet.bytes) catch continue;
            var owns_command = true;
            defer if (owns_command) command.deinit(self.allocator);
            if (try self.accept(command)) owns_command = false;
            if (self.last_applied) |acknowledgement| try self.sendAcknowledgement(net, acknowledgement);
        }
    }

    pub fn next(self: *CommandServer) ?InputCommand {
        if (self.delivered.items.len == 0) return null;
        return self.delivered.orderedRemove(0);
    }

    fn accept(self: *CommandServer, command: InputCommand) !bool {
        if (command.sequence == self.expected_sequence) {
            try self.delivered.ensureUnusedCapacity(self.allocator, self.reordered.items.len + 1);
            self.delivered.appendAssumeCapacity(command);
            self.last_applied = .{ .tick = command.tick, .sequence = command.sequence };
            self.expected_sequence +%= 1;
            self.deliverReordered();
            return true;
        }
        if (!isAfter(command.sequence, self.expected_sequence)) return false;
        for (self.reordered.items) |existing| if (existing.sequence == command.sequence) return false;
        if (self.reordered.items.len >= max_reordered_commands) return false;
        try self.reordered.append(self.allocator, command);
        return true;
    }

    fn deliverReordered(self: *CommandServer) void {
        while (true) {
            const index = self.findReordered(self.expected_sequence) orelse return;
            const command = self.reordered.orderedRemove(index);
            self.delivered.appendAssumeCapacity(command);
            self.last_applied = .{ .tick = command.tick, .sequence = command.sequence };
            self.expected_sequence +%= 1;
        }
    }

    fn sendAcknowledgement(self: *CommandServer, net: transport.Transport, acknowledgement: Acknowledgement) !void {
        var bytes: [acknowledgement_bytes]u8 = undefined;
        try net.send(self.peer, encodeAcknowledgement(&bytes, acknowledgement.tick, acknowledgement.sequence));
    }

    fn findReordered(self: CommandServer, sequence: u32) ?usize {
        for (self.reordered.items, 0..) |command, index| if (command.sequence == sequence) return index;
        return null;
    }
};

fn encodeCommand(destination: []u8, command: InputCommand) ![]u8 {
    if (command.payload.len > max_command_bytes or destination.len < command_header_bytes + command.payload.len) return error.MalformedCommand;
    destination[0] = @intFromEnum(Kind.command);
    std.mem.writeInt(u32, destination[1..5], command.tick, .little);
    std.mem.writeInt(u32, destination[5..9], command.sequence, .little);
    std.mem.writeInt(u16, destination[9..11], @intCast(command.payload.len), .little);
    @memcpy(destination[command_header_bytes..][0..command.payload.len], command.payload);
    return destination[0 .. command_header_bytes + command.payload.len];
}

fn decodeCommand(allocator: std.mem.Allocator, bytes: []const u8) !InputCommand {
    if (bytes.len < command_header_bytes or bytes[0] != @intFromEnum(Kind.command)) return error.MalformedCommand;
    const payload_len: usize = std.mem.readInt(u16, bytes[9..11], .little);
    if (payload_len > max_command_bytes or bytes.len != command_header_bytes + payload_len) return error.MalformedCommand;
    return .{ .tick = std.mem.readInt(u32, bytes[1..5], .little), .sequence = std.mem.readInt(u32, bytes[5..9], .little), .payload = try allocator.dupe(u8, bytes[command_header_bytes..]) };
}

fn encodeAcknowledgement(destination: []u8, tick: u32, sequence: u32) []u8 {
    destination[0] = @intFromEnum(Kind.acknowledgement);
    std.mem.writeInt(u32, destination[1..5], tick, .little);
    std.mem.writeInt(u32, destination[5..9], sequence, .little);
    return destination[0..acknowledgement_bytes];
}

fn decodeAcknowledgement(bytes: []const u8) !struct { tick: u32, sequence: u32 } {
    if (bytes.len != acknowledgement_bytes or bytes[0] != @intFromEnum(Kind.acknowledgement)) return error.MalformedAcknowledgement;
    return .{ .tick = std.mem.readInt(u32, bytes[1..5], .little), .sequence = std.mem.readInt(u32, bytes[5..9], .little) };
}

fn isAfter(sequence: u32, reference: u32) bool {
    return sequence != reference and @as(i32, @bitCast(sequence -% reference)) > 0;
}

test "delayed loopback interpolation is smooth and commands are server ordered" {
    var interpolator = try Interpolator.init(std.testing.allocator, .{ .delay_ms = 25 });
    defer interpolator.deinit();
    try interpolator.push(.{ .tick = 0, .received_at_ms = 0, .position = .{ .x = 0, .y = 0 } });
    try interpolator.push(.{ .tick = 2, .received_at_ms = 200, .position = .{ .x = 20, .y = 0 } });
    try interpolator.push(.{ .tick = 1, .received_at_ms = 100, .position = .{ .x = 10, .y = 0 } });
    try std.testing.expectEqual(Vec2{ .x = 15, .y = 0 }, interpolator.sample(175).?);

    var client_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer client_endpoint.deinit();
    var server_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer server_endpoint.deinit();
    transport.Loopback.pair(&client_endpoint, &server_endpoint);
    var client = CommandClient.init(std.testing.allocator, .{ .id = 2 });
    defer client.deinit();
    var server = CommandServer.init(std.testing.allocator, .{ .id = 1 });
    defer server.deinit();

    try client.send(client_endpoint.transport(), 10, "right");
    try client.send(client_endpoint.transport(), 11, "up");
    std.mem.swap(transport.Received, &server_endpoint.inbox.items[0], &server_endpoint.inbox.items[1]);
    try server.poll(server_endpoint.transport());
    try client.poll(client_endpoint.transport());
    var first = server.next() orelse return error.TestExpectedEqual;
    defer first.deinit(std.testing.allocator);
    var second = server.next() orelse return error.TestExpectedEqual;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 10), first.tick);
    try std.testing.expectEqualStrings("right", first.payload);
    try std.testing.expectEqual(@as(u32, 11), second.tick);
    try std.testing.expectEqualStrings("up", second.payload);
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try std.testing.expectEqual(@as(?u32, 11), client.last_server_tick);
}
