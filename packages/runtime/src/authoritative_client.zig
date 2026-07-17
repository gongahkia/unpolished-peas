const std = @import("std");
const protocol = @import("minna-san-protocol");
const host = @import("authoritative_host.zig");

pub const AuthoritativeClientState = enum { idle, connecting, handshaking, active, disconnected };
pub const AuthoritativeClientError = error{ InvalidConfiguration, InvalidState, IdentityMismatch, ProtocolMismatch, ChannelMismatch, InputTooLarge, InputSequenceExhausted, AuthoritativeOutOfOrder };

pub const AuthoritativeClientConfig = struct {
    local_peer: host.HostPeerId,
    host_peer: host.HostPeerId,
    input_channel: host.HostChannelId,
    event_channel: host.HostChannelId,
    maximum_input_bytes: usize,
};

pub const ClientHello = struct {
    client: host.HostPeerId,
    host: host.HostPeerId,
    version: protocol.WireVersion = protocol.v1_version,
};

pub const HostWelcome = struct {
    client: host.HostPeerId,
    host: host.HostPeerId,
    version: protocol.WireVersion,
    input_channel: host.HostChannelId,
    event_channel: host.HostChannelId,
};

pub const ClientInput = struct {
    sequence: u64,
    channel: host.HostChannelId,
    payload: []const u8,
};

pub const AuthoritativeEvent = struct {
    sequence: u64,
    channel: host.HostChannelId,
    payload: []const u8,
};

pub const AuthoritativeClient = struct {
    config: AuthoritativeClientConfig,
    state: AuthoritativeClientState = .idle,
    next_input_sequence: u64 = 0,
    next_event_sequence: u64 = 0,

    pub fn init(config: AuthoritativeClientConfig) AuthoritativeClientError!AuthoritativeClient {
        if (config.local_peer == 0 or config.host_peer == 0 or config.local_peer == config.host_peer or config.input_channel == 0 or config.event_channel == 0 or config.maximum_input_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn session_state(self: AuthoritativeClient) AuthoritativeClientState {
        return self.state;
    }

    pub fn connect(self: *AuthoritativeClient) AuthoritativeClientError!void {
        switch (self.state) {
            .idle => self.state = .connecting,
            .disconnected => {
                self.state = .connecting;
                self.next_input_sequence = 0;
                self.next_event_sequence = 0;
            },
            else => return error.InvalidState,
        }
    }

    pub fn begin_handshake(self: *AuthoritativeClient) AuthoritativeClientError!ClientHello {
        if (self.state != .connecting) return error.InvalidState;
        self.state = .handshaking;
        return .{ .client = self.config.local_peer, .host = self.config.host_peer };
    }

    pub fn accept_welcome(self: *AuthoritativeClient, welcome: HostWelcome) AuthoritativeClientError!void {
        if (self.state != .handshaking) return error.InvalidState;
        if (welcome.client != self.config.local_peer or welcome.host != self.config.host_peer) return error.IdentityMismatch;
        protocol.validate_version(welcome.version) catch return error.ProtocolMismatch;
        if (welcome.input_channel != self.config.input_channel or welcome.event_channel != self.config.event_channel) return error.ChannelMismatch;
        self.state = .active;
    }

    pub fn send_input(self: *AuthoritativeClient, payload: []const u8) AuthoritativeClientError!ClientInput {
        if (self.state != .active) return error.InvalidState;
        if (payload.len > self.config.maximum_input_bytes) return error.InputTooLarge;
        if (self.next_input_sequence == std.math.maxInt(u64)) return error.InputSequenceExhausted;
        const input = ClientInput{ .sequence = self.next_input_sequence, .channel = self.config.input_channel, .payload = payload };
        self.next_input_sequence += 1;
        return input;
    }

    pub fn consume_authoritative_event(self: *AuthoritativeClient, event: AuthoritativeEvent) AuthoritativeClientError!void {
        if (self.state != .active) return error.InvalidState;
        if (event.channel != self.config.event_channel or event.sequence != self.next_event_sequence) return error.AuthoritativeOutOfOrder;
        self.next_event_sequence += 1;
    }

    pub fn disconnect(self: *AuthoritativeClient) AuthoritativeClientError!void {
        switch (self.state) {
            .connecting, .handshaking, .active => self.state = .disconnected,
            else => return error.InvalidState,
        }
    }
};

test "authoritative clients connect handshake send bounded inputs and consume ordered events" {
    var client = try AuthoritativeClient.init(.{ .local_peer = 2, .host_peer = 1, .input_channel = 10, .event_channel = 11, .maximum_input_bytes = 4 });
    try std.testing.expectError(error.InvalidState, client.send_input("x"));
    try client.connect();
    try std.testing.expectEqual(AuthoritativeClientState.connecting, client.session_state());
    try std.testing.expectEqual(ClientHello{ .client = 2, .host = 1 }, try client.begin_handshake());
    try std.testing.expectError(error.ProtocolMismatch, client.accept_welcome(.{ .client = 2, .host = 1, .version = .{ .major = 2, .minor = 0 }, .input_channel = 10, .event_channel = 11 }));
    try client.accept_welcome(.{ .client = 2, .host = 1, .version = protocol.v1_version, .input_channel = 10, .event_channel = 11 });
    try std.testing.expectEqual(AuthoritativeClientState.active, client.session_state());
    try std.testing.expectEqual(ClientInput{ .sequence = 0, .channel = 10, .payload = "move" }, try client.send_input("move"));
    try std.testing.expectError(error.InputTooLarge, client.send_input("large"));
    try client.consume_authoritative_event(.{ .sequence = 0, .channel = 11, .payload = "state" });
    try std.testing.expectError(error.AuthoritativeOutOfOrder, client.consume_authoritative_event(.{ .sequence = 2, .channel = 11, .payload = "skip" }));
    try client.disconnect();
    try std.testing.expectError(error.InvalidState, client.send_input("x"));
}

test "authoritative clients reject invalid identity channels lifecycle and configuration" {
    try std.testing.expectError(error.InvalidConfiguration, AuthoritativeClient.init(.{ .local_peer = 1, .host_peer = 1, .input_channel = 1, .event_channel = 2, .maximum_input_bytes = 1 }));
    var client = try AuthoritativeClient.init(.{ .local_peer = 2, .host_peer = 1, .input_channel = 3, .event_channel = 4, .maximum_input_bytes = 1 });
    try client.connect();
    _ = try client.begin_handshake();
    try std.testing.expectError(error.IdentityMismatch, client.accept_welcome(.{ .client = 3, .host = 1, .version = protocol.v1_version, .input_channel = 3, .event_channel = 4 }));
    try std.testing.expectError(error.ChannelMismatch, client.accept_welcome(.{ .client = 2, .host = 1, .version = protocol.v1_version, .input_channel = 3, .event_channel = 5 }));
    try client.accept_welcome(.{ .client = 2, .host = 1, .version = protocol.v1_version, .input_channel = 3, .event_channel = 4 });
    try client.disconnect();
    try client.connect();
    try std.testing.expectEqual(AuthoritativeClientState.connecting, client.session_state());
}
