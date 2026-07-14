const std = @import("std");
const Vec2 = @import("math.zig").Vec2;
const snapshot_mod = @import("net_snapshot.zig");
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
        _ = try self.sendWithSequence(net, tick, payload);
    }

    pub fn sendWithSequence(self: *CommandClient, net: transport.Transport, tick: u32, payload: []const u8) !u32 {
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
        return sequence;
    }

    pub fn retransmitPending(self: *CommandClient, net: transport.Transport) !void {
        for (self.pending.items) |command| {
            var bytes: [command_header_bytes + max_command_bytes]u8 = undefined;
            try net.send(self.peer, try encodeCommand(&bytes, command));
        }
    }

    pub fn poll(self: *CommandClient, net: transport.Transport) !void {
        try net.poll();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (packet.from.id != self.peer.id) continue;
            _ = self.handlePacket(packet.bytes);
        }
    }

    pub fn handlePacket(self: *CommandClient, bytes: []const u8) bool {
        const acknowledgement = decodeAcknowledgement(bytes) catch return false;
        self.last_server_tick = acknowledgement.tick;
        self.acknowledge(acknowledgement.sequence);
        return true;
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

const predicted_input_bytes: usize = 8;
const authoritative_state_bytes: usize = 16;
const snapshot_envelope_tag: u8 = 0x7f;
const no_command_sequence: u32 = std.math.maxInt(u32);

pub const PredictionConfig = struct {
    history_limit: usize = 64,
    interpolation: InterpolationConfig = .{},
    snapshot_history_limit: usize = 32,
};

pub const AuthoritativeState = struct {
    tick: u32 = 0,
    last_command_sequence: ?u32 = null,
    position: Vec2 = .{},
};

pub const PredictionClient = struct { // owns command, snapshot, interpolation, and prediction history; call deinit once.
    allocator: std.mem.Allocator,
    config: PredictionConfig,
    peer: transport.Peer,
    commands: CommandClient,
    snapshots: snapshot_mod.Client,
    interpolator: Interpolator,
    predicted_position: Vec2,
    history: std.ArrayListUnmanaged(PredictedInput) = .{},

    const PredictedInput = struct { tick: u32, sequence: u32, delta: Vec2 };

    pub fn init(allocator: std.mem.Allocator, peer: transport.Peer, initial_position: Vec2, config: PredictionConfig) !PredictionClient {
        if (config.history_limit == 0) return error.InvalidPredictionConfig;
        var client = PredictionClient{
            .allocator = allocator,
            .config = config,
            .peer = peer,
            .commands = CommandClient.init(allocator, peer),
            .snapshots = try snapshot_mod.Client.init(allocator, .{ .history_limit = config.snapshot_history_limit }),
            .interpolator = undefined,
            .predicted_position = initial_position,
        };
        errdefer client.snapshots.deinit();
        client.interpolator = try Interpolator.init(allocator, config.interpolation);
        return client;
    }

    pub fn deinit(self: *PredictionClient) void {
        self.history.deinit(self.allocator);
        self.interpolator.deinit();
        self.snapshots.deinit();
        self.commands.deinit();
        self.* = undefined;
    }

    pub fn submit(self: *PredictionClient, net: transport.Transport, tick: u32, delta: Vec2) !void {
        if (self.history.items.len >= self.config.history_limit) return error.PredictionHistoryFull;
        try self.history.ensureUnusedCapacity(self.allocator, 1);
        var payload: [predicted_input_bytes]u8 = undefined;
        const sequence = try self.commands.sendWithSequence(net, tick, encodePredictedInput(&payload, delta));
        self.history.appendAssumeCapacity(.{ .tick = tick, .sequence = sequence, .delta = delta });
        self.predicted_position = self.predicted_position.add(delta);
    }

    pub fn retransmitPending(self: *PredictionClient, net: transport.Transport) !void {
        try self.commands.retransmitPending(net);
    }

    pub fn poll(self: *PredictionClient, net: transport.Transport) !void {
        try net.poll();
        const received_at_ms = net.now();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (packet.from.id != self.peer.id) continue;
            if (packet.bytes.len > 1 and packet.bytes[0] == snapshot_envelope_tag) {
                self.applySnapshot(packet.bytes[1..], received_at_ms) catch |err| switch (err) {
                    error.MissingBaseline => {},
                    else => return err,
                };
                continue;
            }
            _ = self.commands.handlePacket(packet.bytes);
        }
    }

    pub fn snapshotAcknowledgement(self: PredictionClient) ?u32 {
        if (self.snapshots.recovery_required) return null;
        return self.snapshots.acknowledgement();
    }

    pub fn interpolatedPosition(self: PredictionClient, now_ms: u64) Vec2 {
        return self.interpolator.sample(now_ms) orelse self.predicted_position;
    }

    pub fn assertConverged(self: PredictionClient, authoritative: AuthoritativeState) !void {
        if (self.history.items.len != 0 or !std.meta.eql(self.predicted_position, authoritative.position)) return error.SimulationDiverged;
    }

    fn applySnapshot(self: *PredictionClient, packet: []const u8, received_at_ms: u64) !void {
        const previous_id = self.snapshots.acknowledgement();
        try self.snapshots.apply(packet);
        if (self.snapshots.acknowledgement() == previous_id) return;
        const encoded = self.snapshots.state() orelse return error.MissingAuthoritativeState;
        const state = try decodeAuthoritativeState(encoded);
        self.reconcile(state);
        try self.interpolator.push(.{ .tick = state.tick, .received_at_ms = received_at_ms, .position = state.position });
    }

    fn reconcile(self: *PredictionClient, authoritative: AuthoritativeState) void {
        if (authoritative.last_command_sequence) |sequence| {
            var index: usize = 0;
            while (index < self.history.items.len) {
                if (isAfter(self.history.items[index].sequence, sequence)) {
                    index += 1;
                    continue;
                }
                _ = self.history.orderedRemove(index);
            }
        }
        self.predicted_position = authoritative.position;
        for (self.history.items) |input| self.predicted_position = self.predicted_position.add(input.delta);
    }
};

pub const AuthoritativeServer = struct { // owns command and snapshot histories allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    commands: CommandServer,
    snapshots: snapshot_mod.Publisher,
    state: AuthoritativeState,

    pub fn init(allocator: std.mem.Allocator, peer: transport.Peer, initial_position: Vec2, config: PredictionConfig) !AuthoritativeServer {
        return .{
            .allocator = allocator,
            .commands = CommandServer.init(allocator, peer),
            .snapshots = try snapshot_mod.Publisher.init(allocator, .{ .history_limit = config.snapshot_history_limit }),
            .state = .{ .position = initial_position },
        };
    }

    pub fn deinit(self: *AuthoritativeServer) void {
        self.snapshots.deinit();
        self.commands.deinit();
        self.* = undefined;
    }

    pub fn poll(self: *AuthoritativeServer, net: transport.Transport) !void {
        try self.commands.poll(net);
        while (self.commands.next()) |received| {
            var command = received;
            defer command.deinit(self.allocator);
            const delta = try decodePredictedInput(command.payload);
            self.state.tick = command.tick;
            self.state.last_command_sequence = command.sequence;
            self.state.position = self.state.position.add(delta);
        }
    }

    pub fn sendSnapshot(self: *AuthoritativeServer, net: transport.Transport, acknowledged_snapshot: ?u32) !void {
        var encoded_state: [authoritative_state_bytes]u8 = undefined;
        encodeAuthoritativeState(&encoded_state, self.state);
        var packet = try self.snapshots.publish(acknowledged_snapshot, &encoded_state);
        defer packet.deinit(self.allocator);
        var envelope: [snapshot_mod.max_state_bytes + snapshot_mod.header_bytes + 1]u8 = undefined;
        if (packet.bytes.len + 1 > envelope.len) return error.SnapshotTooLarge;
        envelope[0] = snapshot_envelope_tag;
        @memcpy(envelope[1..][0..packet.bytes.len], packet.bytes);
        try net.send(self.commands.peer, envelope[0 .. packet.bytes.len + 1]);
    }
};

fn encodePredictedInput(destination: *[predicted_input_bytes]u8, delta: Vec2) []const u8 {
    std.mem.writeInt(u32, destination[0..4], @bitCast(delta.x), .little);
    std.mem.writeInt(u32, destination[4..8], @bitCast(delta.y), .little);
    return destination;
}

fn decodePredictedInput(source: []const u8) !Vec2 {
    if (source.len != predicted_input_bytes) return error.MalformedPredictedInput;
    return .{
        .x = @bitCast(std.mem.readInt(u32, source[0..4], .little)),
        .y = @bitCast(std.mem.readInt(u32, source[4..8], .little)),
    };
}

fn encodeAuthoritativeState(destination: *[authoritative_state_bytes]u8, state: AuthoritativeState) void {
    std.mem.writeInt(u32, destination[0..4], state.tick, .little);
    std.mem.writeInt(u32, destination[4..8], state.last_command_sequence orelse no_command_sequence, .little);
    std.mem.writeInt(u32, destination[8..12], @bitCast(state.position.x), .little);
    std.mem.writeInt(u32, destination[12..16], @bitCast(state.position.y), .little);
}

fn decodeAuthoritativeState(source: []const u8) !AuthoritativeState {
    if (source.len != authoritative_state_bytes) return error.MalformedAuthoritativeState;
    const sequence = std.mem.readInt(u32, source[4..8], .little);
    return .{
        .tick = std.mem.readInt(u32, source[0..4], .little),
        .last_command_sequence = if (sequence == no_command_sequence) null else sequence,
        .position = .{
            .x = @bitCast(std.mem.readInt(u32, source[8..12], .little)),
            .y = @bitCast(std.mem.readInt(u32, source[12..16], .little)),
        },
    };
}

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

test "prediction reconciles a bounded history through seeded loss and reordering" {
    var network = try @import("net_fault.zig").Network.init(std.testing.allocator, .{
        .seed = 122,
        .latency_ms = 2,
        .jitter_ms = 3,
        .loss_per_mille = 200,
        .duplicate_per_mille = 200,
        .reorder_per_mille = 250,
        .reorder_delay_ms = 7,
    });
    defer network.deinit();
    var client_endpoint = @import("net_fault.zig").Endpoint.init(std.testing.allocator, &network, .{ .id = 1 });
    defer client_endpoint.deinit();
    var server_endpoint = @import("net_fault.zig").Endpoint.init(std.testing.allocator, &network, .{ .id = 2 });
    defer server_endpoint.deinit();
    @import("net_fault.zig").Endpoint.pair(&client_endpoint, &server_endpoint);
    const config = PredictionConfig{ .history_limit = 64, .interpolation = .{ .delay_ms = 16, .max_snapshots = 16 }, .snapshot_history_limit = 16 };
    var client = try PredictionClient.init(std.testing.allocator, .{ .id = 2 }, .{}, config);
    defer client.deinit();
    var server = try AuthoritativeServer.init(std.testing.allocator, .{ .id = 1 }, .{}, config);
    defer server.deinit();

    var tick: u32 = 1;
    while (tick <= 48) : (tick += 1) {
        const delta = if (tick % 2 == 0) Vec2{ .x = 1, .y = 0 } else Vec2{ .x = 0, .y = 0.5 };
        try client.submit(client_endpoint.asTransport(), tick, delta);
        try client.retransmitPending(client_endpoint.asTransport());
        network.advance(16);
        try server.poll(server_endpoint.asTransport());
        try server.sendSnapshot(server_endpoint.asTransport(), client.snapshotAcknowledgement());
        network.advance(16);
        try client.poll(client_endpoint.asTransport());
        try std.testing.expect(client.history.items.len <= config.history_limit);
    }

    var flush: usize = 0;
    while (flush < 256 and client.history.items.len != 0) : (flush += 1) {
        try client.retransmitPending(client_endpoint.asTransport());
        network.advance(16);
        try server.poll(server_endpoint.asTransport());
        try server.sendSnapshot(server_endpoint.asTransport(), client.snapshotAcknowledgement());
        network.advance(16);
        try client.poll(client_endpoint.asTransport());
    }
    try client.assertConverged(server.state);
    try std.testing.expect(!std.meta.eql(client.interpolatedPosition(network.now_ms), Vec2.zero));
}
