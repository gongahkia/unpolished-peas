const std = @import("std");
const ipv4 = @import("ipv4.zig");
const tcp_connection = @import("tcp_connection.zig");
const tcp_listener = @import("tcp_listener.zig");

pub const tcp_frame_header_bytes: usize = 4;
pub const TcpFrameError = error{ InvalidCapacity, InvalidState, FrameInProgress, MessageTooLarge, MalformedFrame, ConnectionNotConnected, ConnectionClosed, ReadFailed, WriteFailed };

pub const TcpFrameReader = struct {
    storage: []u8,
    header: [tcp_frame_header_bytes]u8 = undefined,
    header_used: usize = 0,
    body_length: ?usize = null,
    body_used: usize = 0,
    failed: bool = false,

    pub fn init(storage: []u8) TcpFrameError!TcpFrameReader {
        if (storage.len > std.math.maxInt(u32)) return error.InvalidCapacity;
        return .{ .storage = storage };
    }

    pub fn read(self: *TcpFrameReader, connection: *tcp_connection.TcpConnection) TcpFrameError!?[]u8 {
        if (self.failed) return error.InvalidState;
        const handle = try socket_handle(connection);
        while (true) {
            if (self.body_length) |length| {
                if (length == 0) {
                    self.reset();
                    return self.storage[0..0];
                }
                const received = std.posix.recv(handle, self.storage[self.body_used..length], 0) catch |err| switch (err) {
                    error.WouldBlock => return null,
                    else => return error.ReadFailed,
                };
                if (received == 0) return error.ConnectionClosed;
                self.body_used += received;
                if (self.body_used == length) {
                    const frame = self.storage[0..length];
                    self.reset();
                    return frame;
                }
                continue;
            }

            const received = std.posix.recv(handle, self.header[self.header_used..], 0) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return error.ReadFailed,
            };
            if (received == 0) return error.ConnectionClosed;
            self.header_used += received;
            if (self.header_used != tcp_frame_header_bytes) continue;
            const length: usize = std.mem.readInt(u32, self.header[0..], .big);
            if (length > self.storage.len) {
                self.failed = true;
                return error.MalformedFrame;
            }
            self.body_length = length;
        }
    }

    fn reset(self: *TcpFrameReader) void {
        self.header_used = 0;
        self.body_length = null;
        self.body_used = 0;
    }
};

pub const TcpFrameWriter = struct {
    max_message_bytes: usize,
    header: [tcp_frame_header_bytes]u8 = undefined,
    header_sent: usize = 0,
    payload: ?[]const u8 = null,
    payload_sent: usize = 0,

    pub fn init(max_message_bytes: usize) TcpFrameError!TcpFrameWriter {
        if (max_message_bytes > std.math.maxInt(u32)) return error.InvalidCapacity;
        return .{ .max_message_bytes = max_message_bytes };
    }

    pub fn begin(self: *TcpFrameWriter, payload: []const u8) TcpFrameError!void {
        if (self.payload != null) return error.FrameInProgress;
        if (payload.len > self.max_message_bytes) return error.MessageTooLarge;
        std.mem.writeInt(u32, self.header[0..], @intCast(payload.len), .big);
        self.payload = payload;
        self.header_sent = 0;
        self.payload_sent = 0;
    }

    pub fn flush(self: *TcpFrameWriter, connection: *tcp_connection.TcpConnection) TcpFrameError!bool {
        const handle = try socket_handle(connection);
        const payload = self.payload orelse return error.InvalidState;
        while (self.header_sent < tcp_frame_header_bytes) {
            const sent = std.posix.send(handle, self.header[self.header_sent..], 0) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return error.WriteFailed,
            };
            if (sent == 0) return error.WriteFailed;
            self.header_sent += sent;
        }
        while (self.payload_sent < payload.len) {
            const sent = std.posix.send(handle, payload[self.payload_sent..], 0) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return error.WriteFailed,
            };
            if (sent == 0) return error.WriteFailed;
            self.payload_sent += sent;
        }
        self.payload = null;
        self.header_sent = 0;
        self.payload_sent = 0;
        return true;
    }
};

fn socket_handle(connection: *tcp_connection.TcpConnection) TcpFrameError!std.posix.socket_t {
    if (connection.state != .connected) return error.ConnectionNotConnected;
    const socket = connection.socket orelse return error.ConnectionNotConnected;
    return socket.handle;
}

const ConnectedPair = struct {
    client: tcp_connection.TcpConnection,
    server: tcp_connection.TcpConnection,
};

fn connected_pair() !ConnectedPair {
    var listener = try tcp_listener.TcpListener.init(ipv4.Ipv4Address.wildcard(0), 1);
    defer listener.shutdown();
    const endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    var client = try tcp_connection.TcpConnection.init();
    errdefer client.close();
    _ = try client.start_connect(endpoint, 1_000);
    var pending = try accept_with_retry(&listener);
    const admitted = listener.admit(&pending, .allow) orelse unreachable;
    var elapsed_ms: u32 = 0;
    while (client.state == .connecting and elapsed_ms < 1_000) : (elapsed_ms += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
        _ = try client.complete(elapsed_ms);
    }
    if (client.state != .connected) return error.ConnectionNotConnected;
    return .{ .client = client, .server = admitted.connection };
}

fn accept_with_retry(listener: *tcp_listener.TcpListener) !tcp_listener.TcpPendingConnection {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        return listener.accept() catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.WouldBlock;
}

fn send_all(connection: *tcp_connection.TcpConnection, bytes: []const u8) !void {
    const handle = connection.socket orelse return error.ConnectionNotConnected;
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += std.posix.send(handle.handle, bytes[sent..], 0) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
}

fn read_with_retry(reader: *TcpFrameReader, connection: *tcp_connection.TcpConnection) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try reader.read(connection)) |frame| return frame;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.WouldBlock;
}

test "framed TCP readers retain partial headers and bodies in bounded storage" {
    var pair = try connected_pair();
    defer pair.client.close();
    defer pair.server.close();
    var storage: [8]u8 = undefined;
    var reader = try TcpFrameReader.init(storage[0..]);
    try send_all(&pair.client, &.{ 0, 0 });
    try std.testing.expect((try reader.read(&pair.server)) == null);
    try send_all(&pair.client, &.{ 0, 5, 'h', 'e' });
    try std.testing.expect((try reader.read(&pair.server)) == null);
    try send_all(&pair.client, "llo");
    try std.testing.expectEqualStrings("hello", try read_with_retry(&reader, &pair.server));
}

test "framed TCP writers emit bounded messages and reject malformed frames" {
    var pair = try connected_pair();
    defer pair.client.close();
    defer pair.server.close();
    var storage: [8]u8 = undefined;
    var reader = try TcpFrameReader.init(storage[0..]);
    var writer = try TcpFrameWriter.init(8);
    try writer.begin("frame");
    try std.testing.expect(try writer.flush(&pair.client));
    try std.testing.expectEqualStrings("frame", try read_with_retry(&reader, &pair.server));
    try std.testing.expectError(error.MessageTooLarge, writer.begin("too-large"));

    var malformed_storage: [3]u8 = undefined;
    var malformed_reader = try TcpFrameReader.init(malformed_storage[0..]);
    try send_all(&pair.client, &.{ 0, 0, 0, 4 });
    var malformed = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        _ = malformed_reader.read(&pair.server) catch |err| {
            if (err == error.MalformedFrame) {
                malformed = true;
                break;
            }
            return err;
        };
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(malformed);
    try std.testing.expectError(error.InvalidState, malformed_reader.read(&pair.server));
}
