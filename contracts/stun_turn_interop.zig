const std = @import("std");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");

const FixtureError = error{ UnexpectedMessage, FixtureTimeout, FixtureMessageTooLarge, ConnectionClosed };
const fixture_attempts: usize = 100;
const fixture_relay = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 203, 0, 113, 1 }, .port = 5000 } };
const fixture_lifetime_seconds: u32 = 60;

fn localUdpAddress(socket: *transport.UdpSocket) !transport.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &length);
    return transport.Ipv4Address.from_native(native);
}

fn receiveUdp(socket: *transport.UdpSocket, storage: []u8) !transport.ReceivedDatagram {
    var attempts: usize = 0;
    while (attempts < fixture_attempts) : (attempts += 1) {
        return socket.receive_from(storage) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.FixtureTimeout;
}

fn acceptTcp(listener: *transport.TcpListener) !transport.TcpPendingConnection {
    var attempts: usize = 0;
    while (attempts < fixture_attempts) : (attempts += 1) {
        return listener.accept() catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.FixtureTimeout;
}

const TcpPair = struct {
    client: transport.TcpConnection,
    server: transport.TcpConnection,
    endpoint: transport.Ipv4Address,

    fn close(self: *TcpPair) void {
        self.client.close();
        self.server.close();
    }
};

fn openTcpPair() !TcpPair {
    var listener = try transport.TcpListener.init(transport.Ipv4Address.wildcard(0), 1);
    defer listener.shutdown();
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    var client = try transport.TcpConnection.init();
    errdefer client.close();
    _ = try client.start_connect(endpoint, 1_000);
    var pending = try acceptTcp(&listener);
    const admitted = listener.admit(&pending, .allow) orelse return error.UnexpectedMessage;
    var elapsed_ms: u32 = 0;
    while (client.state == .connecting and elapsed_ms < 1_000) : (elapsed_ms += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
        _ = try client.complete(elapsed_ms);
    }
    if (client.state != .connected) return error.FixtureTimeout;
    return .{ .client = client, .server = admitted.connection, .endpoint = endpoint };
}

fn sendTcp(connection: *transport.TcpConnection, bytes: []const u8) !void {
    const socket = connection.socket orelse return error.ConnectionClosed;
    var sent: usize = 0;
    var attempts: usize = 0;
    while (sent < bytes.len) {
        const count = std.posix.send(socket.handle, bytes[sent..], 0) catch |err| switch (err) {
            error.WouldBlock => {
                if (attempts == fixture_attempts) return error.FixtureTimeout;
                attempts += 1;
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) return error.ConnectionClosed;
        sent += count;
        attempts = 0;
    }
}

fn readTcpExact(connection: *transport.TcpConnection, output: []u8) !void {
    const socket = connection.socket orelse return error.ConnectionClosed;
    var received: usize = 0;
    var attempts: usize = 0;
    while (received < output.len) {
        const count = std.posix.recv(socket.handle, output[received..], 0) catch |err| switch (err) {
            error.WouldBlock => {
                if (attempts == fixture_attempts) return error.FixtureTimeout;
                attempts += 1;
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (count == 0) return error.ConnectionClosed;
        received += count;
        attempts = 0;
    }
}

fn readTcpStun(connection: *transport.TcpConnection, storage: []u8) ![]u8 {
    if (storage.len < protocol.stun_header_bytes) return error.FixtureMessageTooLarge;
    try readTcpExact(connection, storage[0..protocol.stun_header_bytes]);
    const attribute_bytes: usize = std.mem.readInt(u16, storage[2..4], .big);
    const message_bytes = protocol.stun_header_bytes + attribute_bytes;
    if (message_bytes > storage.len) return error.FixtureMessageTooLarge;
    try readTcpExact(connection, storage[protocol.stun_header_bytes..message_bytes]);
    return storage[0..message_bytes];
}

fn fixtureResponse(request: []const u8, mapped: protocol.StunAddress, reject_allocate: bool, output: []u8) ![]u8 {
    var attributes: [5]protocol.StunAttribute = undefined;
    const decoded = try protocol.decode_stun_message(request, attributes[0..]);
    if (decoded.header.class != .request) return error.UnexpectedMessage;
    return switch (decoded.header.method) {
        1 => blk: {
            if (decoded.count != 0) return error.UnexpectedMessage;
            var address: [20]u8 = undefined;
            const value = try protocol.encode_xor_address(mapped, decoded.header.transaction_id, address[0..]);
            break :blk protocol.encode_stun_message(.{ .method = 1, .class = .success_response, .transaction_id = decoded.header.transaction_id }, &.{.{ .kind = 0x0020, .value = value }}, output);
        },
        3 => blk: {
            if (!hasAttribute(attributes[0..decoded.count], 0x0019)) return error.UnexpectedMessage;
            if (reject_allocate) break :blk protocol.encode_stun_message(.{ .method = 3, .class = .error_response, .transaction_id = decoded.header.transaction_id }, &.{}, output);
            var address: [20]u8 = undefined;
            var lifetime: [4]u8 = undefined;
            const value = try protocol.encode_xor_address(fixture_relay, decoded.header.transaction_id, address[0..]);
            std.mem.writeInt(u32, lifetime[0..], fixture_lifetime_seconds, .big);
            break :blk protocol.encode_stun_message(.{ .method = 3, .class = .success_response, .transaction_id = decoded.header.transaction_id }, &.{ .{ .kind = 0x0016, .value = value }, .{ .kind = 0x000d, .value = lifetime[0..] } }, output);
        },
        else => error.UnexpectedMessage,
    };
}

fn hasAttribute(attributes: []const protocol.StunAttribute, kind: u16) bool {
    for (attributes) |attribute| if (attribute.kind == kind) return true;
    return false;
}

fn decodeFixtureResponse(bytes: []const u8, attributes: []protocol.StunAttribute) !struct { header: protocol.StunHeader, attributes: []const protocol.StunAttribute } {
    const decoded = try protocol.decode_stun_message(bytes, attributes);
    return .{ .header = decoded.header, .attributes = attributes[0..decoded.count] };
}

test "controlled UDP STUN TURN fixture runs binding allocation and rejection clients" {
    var server = try transport.UdpSocket.init(.{});
    defer server.close();
    try server.bind(transport.Ipv4Address.wildcard(0));
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try localUdpAddress(&server)).port);
    var client_socket = try transport.UdpSocket.init(.{});
    defer client_socket.close();
    try client_socket.bind(transport.Ipv4Address.wildcard(0));

    var binding = try topology.UdpStunBindingClient.init(.{ .server = endpoint, .initial_rto_ns = 1, .maximum_retransmissions = 2 }, .{1} ** 12);
    const send = try binding.begin(0);
    var request: [protocol.stun_header_bytes]u8 = undefined;
    const request_bytes = try protocol.encode_stun_message(.{ .method = 1, .class = .request, .transaction_id = send.transaction_id }, &.{}, request[0..]);
    _ = try client_socket.send_to(request_bytes, send.server);
    var server_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    const received_request = try receiveUdp(&server, server_storage[0..]);
    var response: [128]u8 = undefined;
    const mapped = protocol.StunAddress{ .ipv4 = .{ .octets = received_request.source.octets, .port = received_request.source.port } };
    _ = try server.send_to(try fixtureResponse(received_request.bytes, mapped, false, response[0..]), received_request.source);
    var client_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    const received_response = try receiveUdp(&client_socket, client_storage[0..]);
    var response_attributes: [2]protocol.StunAttribute = undefined;
    const decoded_response = try decodeFixtureResponse(received_response.bytes, response_attributes[0..]);
    try std.testing.expectEqual(mapped, (try binding.receive(decoded_response.header, decoded_response.attributes)).mapped);

    const credentials = protocol.StunLongTermCredentials{ .username = "u", .password = "p", .realm = "r", .nonce = "n", .algorithm = .sha256 };
    var allocation = try topology.TurnAllocationClient.init(.{ .server = endpoint, .credentials = credentials, .requested_lifetime_seconds = fixture_lifetime_seconds }, .{2} ** 12);
    var allocation_request: [128]u8 = undefined;
    _ = try client_socket.send_to(try allocation.begin(10, allocation_request[0..]), endpoint);
    const received_allocation = try receiveUdp(&server, server_storage[0..]);
    _ = try server.send_to(try fixtureResponse(received_allocation.bytes, mapped, false, response[0..]), received_allocation.source);
    const received_allocation_response = try receiveUdp(&client_socket, client_storage[0..]);
    const decoded_allocation_response = try decodeFixtureResponse(received_allocation_response.bytes, response_attributes[0..]);
    const allocated = try allocation.receive(11, decoded_allocation_response.header, decoded_allocation_response.attributes);
    try std.testing.expectEqual(fixture_relay, allocated.relay);
    try std.testing.expect(allocated.expires_at_ns > 10);

    var rejected = try topology.TurnAllocationClient.init(.{ .server = endpoint, .credentials = credentials, .requested_lifetime_seconds = fixture_lifetime_seconds }, .{3} ** 12);
    _ = try client_socket.send_to(try rejected.begin(20, allocation_request[0..]), endpoint);
    const rejected_request = try receiveUdp(&server, server_storage[0..]);
    _ = try server.send_to(try fixtureResponse(rejected_request.bytes, mapped, true, response[0..]), rejected_request.source);
    const rejected_response = try receiveUdp(&client_socket, client_storage[0..]);
    const decoded_rejection = try decodeFixtureResponse(rejected_response.bytes, response_attributes[0..]);
    try std.testing.expectError(error.AllocationRejected, rejected.receive(21, decoded_rejection.header, decoded_rejection.attributes));
}

test "controlled TCP STUN TURN fixture runs binding allocation and mismatched-response clients" {
    var pair = try openTcpPair();
    defer pair.close();
    const mapped = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 198, 51, 100, 7 }, .port = 4000 } };

    var binding = try topology.TcpStunBindingClient.init(.{ .server = pair.endpoint, .timeout_ns = 100 }, .{4} ** 12);
    var request: [128]u8 = undefined;
    try sendTcp(&pair.client, try binding.begin(0, request[0..]));
    var server_storage: [128]u8 = undefined;
    const received_binding = try readTcpStun(&pair.server, server_storage[0..]);
    var response: [128]u8 = undefined;
    try sendTcp(&pair.server, try fixtureResponse(received_binding, mapped, false, response[0..]));
    var client_storage: [128]u8 = undefined;
    var response_attributes: [2]protocol.StunAttribute = undefined;
    try std.testing.expectEqual(mapped, try binding.receive_frame(1, try readTcpStun(&pair.client, client_storage[0..]), response_attributes[0..]));

    const credentials = protocol.StunLongTermCredentials{ .username = "u", .password = "p", .realm = "r", .nonce = "n", .algorithm = .sha256 };
    var allocation = try topology.TurnAllocationClient.init(.{ .server = pair.endpoint, .credentials = credentials, .requested_lifetime_seconds = fixture_lifetime_seconds }, .{5} ** 12);
    try sendTcp(&pair.client, try allocation.begin(10, request[0..]));
    const received_allocation = try readTcpStun(&pair.server, server_storage[0..]);
    try sendTcp(&pair.server, try fixtureResponse(received_allocation, mapped, false, response[0..]));
    const allocation_response = try readTcpStun(&pair.client, client_storage[0..]);
    const decoded_allocation = try decodeFixtureResponse(allocation_response, response_attributes[0..]);
    try std.testing.expectEqual(fixture_relay, (try allocation.receive(11, decoded_allocation.header, decoded_allocation.attributes)).relay);

    var mismatched = try topology.TcpStunBindingClient.init(.{ .server = pair.endpoint, .timeout_ns = 100 }, .{6} ** 12);
    try sendTcp(&pair.client, try mismatched.begin(20, request[0..]));
    const received_mismatched = try readTcpStun(&pair.server, server_storage[0..]);
    const mismatched_response = try fixtureResponse(received_mismatched, mapped, false, response[0..]);
    response[8] +%= 1;
    try sendTcp(&pair.server, mismatched_response);
    try std.testing.expectError(error.UnexpectedResponse, mismatched.receive_frame(21, try readTcpStun(&pair.client, client_storage[0..]), response_attributes[0..]));
}
