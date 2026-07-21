const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const fixtures = @import("minna-san-test-support");

pub const DeterministicClock = fixtures.DeterministicClock;
pub const FixedAllocatorFixture = fixtures.FixedAllocatorFixture;
pub const max_transport_messages = fixtures.max_network_messages;
pub const DeterministicTransportError = fixtures.DeterministicNetworkError;
pub const DeterministicTransportConfig = fixtures.DeterministicNetworkConfig;
pub const DeterministicTransportMessage = fixtures.DeterministicNetworkMessage;
pub const DeterministicTransport = fixtures.DeterministicNetwork;

pub fn deterministic_identity(seed: u8) protocol.PublicKeyAuthenticationError!protocol.PublicKeyIdentity {
    return protocol.PublicKeyIdentity.init([_]u8{seed} ** std.crypto.sign.Ed25519.KeyPair.seed_length);
}

pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    try std.testing.expectEqualSlices(T, expected, actual);
}

pub fn expectError(expected_error: anyerror, actual: anytype) !void {
    try std.testing.expectError(expected_error, actual);
}

pub const PropertyGeneratorError = error{
    InvalidConfiguration,
    OutputTooSmall,
};

pub const PropertyGeneratorConfig = struct {
    seed: u64,
    maximum_bytes: usize,
    maximum_schema_version: state.StateSchemaVersion = 16,
};

pub const GeneratedState = struct {
    schema_version: state.StateSchemaVersion,
    bytes: core.BorrowedBuffer,
};

pub const PropertyGenerator = struct {
    config: PropertyGeneratorConfig,
    random: std.Random.DefaultPrng,

    pub fn init(config: PropertyGeneratorConfig) PropertyGeneratorError!PropertyGenerator {
        if (config.maximum_bytes == 0 or config.maximum_bytes > protocol.max_packet_payload_bytes or config.maximum_schema_version == 0) return error.InvalidConfiguration;
        return .{ .config = config, .random = std.Random.DefaultPrng.init(config.seed) };
    }

    pub fn next_protocol_message(self: *PropertyGenerator, output: []u8) PropertyGeneratorError!protocol.WireEnvelope {
        const payload = try self.next_bytes(output);
        const random = self.random.random();
        const extension_id: u16 = if (random.uintLessThan(u8, 2) == 0) 0 else protocol.extension_range.first + random.uintLessThan(u16, protocol.extension_range.last - protocol.extension_range.first + 1);
        return .{ .version = protocol.v1_version, .extension_id = extension_id, .payload = payload };
    }

    pub fn next_address(self: *PropertyGenerator) protocol.StunAddress {
        const random = self.random.random();
        if (random.uintLessThan(u8, 2) == 0) {
            var octets: [4]u8 = undefined;
            random.bytes(&octets);
            return .{ .ipv4 = .{ .octets = octets, .port = random.int(u16) } };
        }
        var octets: [16]u8 = undefined;
        random.bytes(&octets);
        return .{ .ipv6 = .{ .octets = octets, .port = random.int(u16) } };
    }

    pub fn next_route_capabilities(self: *PropertyGenerator) topology.RouteCapabilities {
        return .{
            .direct = self.next_route_availability(),
            .relay = self.next_route_availability(),
            .authoritative = self.next_route_availability(),
        };
    }

    pub fn next_state(self: *PropertyGenerator, output: []u8) PropertyGeneratorError!GeneratedState {
        return .{
            .schema_version = self.random.random().uintLessThan(state.StateSchemaVersion, self.config.maximum_schema_version) + 1,
            .bytes = .init(try self.next_bytes(output)),
        };
    }

    pub fn next_capability_config(self: *PropertyGenerator) core.CapabilityConfig {
        const random = self.random.random();
        return .{
            .transport = random.uintLessThan(u8, 2) != 0,
            .packet_protection = random.uintLessThan(u8, 2) != 0,
            .topology = random.uintLessThan(u8, 2) != 0,
            .state_replication = random.uintLessThan(u8, 2) != 0,
            .capture = random.uintLessThan(u8, 2) != 0,
        };
    }

    pub fn next_valid_capability_config(self: *PropertyGenerator) core.CapabilityConfig {
        var config = self.next_capability_config();
        if (config.packet_protection or config.topology or config.state_replication or config.capture) config.transport = true;
        return config;
    }

    fn next_bytes(self: *PropertyGenerator, output: []u8) PropertyGeneratorError![]const u8 {
        if (output.len < self.config.maximum_bytes) return error.OutputTooSmall;
        const len = self.random.random().uintLessThan(usize, self.config.maximum_bytes + 1);
        self.random.random().bytes(output[0..len]);
        return output[0..len];
    }

    fn next_route_availability(self: *PropertyGenerator) topology.RouteAvailability {
        const random = self.random.random();
        const health = [_]topology.ShardHealth{ .healthy, .degraded, .unavailable };
        return .{ .negotiated = random.uintLessThan(u8, 2) != 0, .health = health[random.uintLessThan(usize, health.len)] };
    }
};

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

test "property generators produce bounded deterministic protocol topology state and capability values" {
    const config = PropertyGeneratorConfig{ .seed = 7, .maximum_bytes = 8, .maximum_schema_version = 3 };
    var first = try PropertyGenerator.init(config);
    var second = try PropertyGenerator.init(config);
    var first_message_storage: [8]u8 = undefined;
    var second_message_storage: [8]u8 = undefined;
    const first_message = try first.next_protocol_message(first_message_storage[0..]);
    const second_message = try second.next_protocol_message(second_message_storage[0..]);
    try protocol.validate_envelope(first_message);
    try std.testing.expectEqual(first_message.extension_id, second_message.extension_id);
    try expectEqualSlices(u8, first_message.payload, second_message.payload);
    const address = first.next_address();
    var encoded_address: [20]u8 = undefined;
    const transaction_id = [_]u8{0} ** 12;
    try std.testing.expectEqual(address, try protocol.decode_xor_address(try protocol.encode_xor_address(address, transaction_id, encoded_address[0..]), transaction_id));
    const routes = first.next_route_capabilities();
    _ = routes.direct.health;
    _ = routes.relay.health;
    _ = routes.authoritative.health;
    var state_storage: [8]u8 = undefined;
    const generated_state = try first.next_state(state_storage[0..]);
    try std.testing.expect(generated_state.schema_version >= 1 and generated_state.schema_version <= config.maximum_schema_version);
    try std.testing.expect(generated_state.bytes.bytes.len <= config.maximum_bytes);
    try (first.next_valid_capability_config()).validate();
}

test "property generators reject invalid bounds and undersized output" {
    try expectError(error.InvalidConfiguration, PropertyGenerator.init(.{ .seed = 0, .maximum_bytes = 0 }));
    try expectError(error.InvalidConfiguration, PropertyGenerator.init(.{ .seed = 0, .maximum_bytes = protocol.max_packet_payload_bytes + 1 }));
    try expectError(error.InvalidConfiguration, PropertyGenerator.init(.{ .seed = 0, .maximum_bytes = 1, .maximum_schema_version = 0 }));
    var generator = try PropertyGenerator.init(.{ .seed = 1, .maximum_bytes = 2 });
    var short_output: [1]u8 = undefined;
    try expectError(error.OutputTooSmall, generator.next_protocol_message(short_output[0..]));
    try expectError(error.OutputTooSmall, generator.next_state(short_output[0..]));
    var invalid_capabilities = core.CapabilityConfig{ .capture = true };
    try expectError(error.UnsupportedCapabilityCombination, invalid_capabilities.validate());
}

test {
    _ = @import("allocator_lifecycle.zig");
    _ = @import("fuzz_envelope_codecs.zig");
    _ = @import("fuzz_http_websocket.zig");
    _ = @import("fuzz_security_handshakes.zig");
    _ = @import("fuzz_topology_migration.zig");
    _ = @import("fuzz_nat_p2p.zig");
}
