const std = @import("std");

pub const max_soak_peers: usize = 1_000;
pub const max_soak_messages_per_peer: usize = 1_000;
pub const TransportSoakError = error{ InvalidConfiguration, ScenarioExhausted };

pub const TransportSoakConfig = struct {
    peers: usize,
    messages_per_peer: usize,
};

pub const TransportSoakEvent = struct {
    peer_index: usize,
    message_index: usize,
};

pub const TransportSoakScenario = struct {
    config: TransportSoakConfig,
    next_index: usize = 0,

    pub fn init(config: TransportSoakConfig) TransportSoakError!TransportSoakScenario {
        if (config.peers == 0 or config.peers > max_soak_peers or config.messages_per_peer == 0 or config.messages_per_peer > max_soak_messages_per_peer) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn total_messages(self: TransportSoakScenario) usize {
        return self.config.peers * self.config.messages_per_peer;
    }

    pub fn next(self: *TransportSoakScenario) ?TransportSoakEvent {
        if (self.next_index == self.total_messages()) return null;
        const event = TransportSoakEvent{
            .peer_index = self.next_index % self.config.peers,
            .message_index = self.next_index / self.config.peers,
        };
        self.next_index += 1;
        return event;
    }

    pub fn reset(self: *TransportSoakScenario) void {
        self.next_index = 0;
    }
};

test "transport soak scenarios are deterministic and 1,000-peer ready" {
    var scenario = try TransportSoakScenario.init(.{ .peers = 3, .messages_per_peer = 2 });
    try std.testing.expectEqual(@as(usize, 6), scenario.total_messages());
    try std.testing.expectEqual(TransportSoakEvent{ .peer_index = 0, .message_index = 0 }, scenario.next().?);
    try std.testing.expectEqual(TransportSoakEvent{ .peer_index = 1, .message_index = 0 }, scenario.next().?);
    try std.testing.expectEqual(TransportSoakEvent{ .peer_index = 2, .message_index = 0 }, scenario.next().?);
    try std.testing.expectEqual(TransportSoakEvent{ .peer_index = 0, .message_index = 1 }, scenario.next().?);
    scenario.reset();
    try std.testing.expectEqual(TransportSoakEvent{ .peer_index = 0, .message_index = 0 }, scenario.next().?);
    try std.testing.expectError(error.InvalidConfiguration, TransportSoakScenario.init(.{ .peers = max_soak_peers + 1, .messages_per_peer = 1 }));
}
