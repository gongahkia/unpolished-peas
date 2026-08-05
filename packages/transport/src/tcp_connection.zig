const std = @import("std");
const ipv4 = @import("ipv4.zig");
const socket_backend = @import("socket_backend.zig");

pub const TcpConnectionState = enum {
    idle,
    connecting,
    connected,
    failed,
    cancelled,
    timed_out,
    closed,
};

pub const TcpConnectionFailure = enum {
    refused,
    failed,
};

pub const TcpConnectionError = error{ InvalidState, PollFailed, ConnectFailed, ConnectionFailed, ConnectionRefused, Cancelled, TimedOut };

pub const TcpConnection = struct {
    socket: ?socket_backend.Socket,
    state: TcpConnectionState = .idle,
    timeout_ms: u32 = 0,
    failure: ?TcpConnectionFailure = null,

    pub fn init() TcpConnectionError!TcpConnection {
        return .{ .socket = socket_backend.Socket.open(.tcp) catch return error.ConnectFailed };
    }

    pub fn start_connect(self: *TcpConnection, peer: ipv4.Ipv4Address, timeout_ms: u32) TcpConnectionError!TcpConnectionState {
        if (self.state != .idle) return error.InvalidState;
        const socket = self.socket orelse return error.InvalidState;
        self.timeout_ms = timeout_ms;
        const native = peer.to_native();
        std.posix.connect(socket.handle, &native.any, native.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionPending => {
                self.state = .connecting;
                return self.state;
            },
            error.ConnectionRefused => {
                self.abandon(.failed, .refused);
                return error.ConnectionRefused;
            },
            else => {
                self.abandon(.failed, .failed);
                return error.ConnectFailed;
            },
        };
        self.state = .connected;
        return self.state;
    }

    pub fn complete(self: *TcpConnection, elapsed_ms: u32) TcpConnectionError!TcpConnectionState {
        switch (self.state) {
            .connected => return .connected,
            .connecting => {},
            .cancelled => return error.Cancelled,
            .timed_out => return error.TimedOut,
            .failed => return if (self.failure == .refused) error.ConnectionRefused else error.ConnectionFailed,
            else => return error.InvalidState,
        }
        if (elapsed_ms >= self.timeout_ms) {
            self.abandon(.timed_out, null);
            return error.TimedOut;
        }
        const socket = self.socket orelse return error.InvalidState;
        var descriptors = [_]std.posix.pollfd{.{
            .fd = socket.handle,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const ready_count = std.posix.poll(&descriptors, 0) catch return error.PollFailed;
        if (ready_count == 0) return .connecting;
        std.posix.getsockoptError(socket.handle) catch |err| switch (err) {
            error.ConnectionPending => return .connecting,
            error.ConnectionRefused => {
                self.abandon(.failed, .refused);
                return error.ConnectionRefused;
            },
            else => {
                self.abandon(.failed, .failed);
                return error.ConnectionFailed;
            },
        };
        self.state = .connected;
        return self.state;
    }

    pub fn cancel(self: *TcpConnection) TcpConnectionError!void {
        if (self.state != .connecting) return error.InvalidState;
        self.abandon(.cancelled, null);
    }

    pub fn close(self: *TcpConnection) void {
        if (self.socket) |*socket| {
            if (self.state == .connected) std.posix.shutdown(socket.handle, .both) catch {};
            socket.close();
            self.socket = null;
        }
        self.state = .closed;
    }

    pub fn failureReason(self: TcpConnection) ?TcpConnectionFailure {
        return self.failure;
    }

    fn abandon(self: *TcpConnection, state: TcpConnectionState, failure: ?TcpConnectionFailure) void {
        if (self.socket) |*socket| socket.close();
        self.socket = null;
        self.state = state;
        self.failure = failure;
    }
};

fn local_address(socket: *socket_backend.Socket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var address_length = native.getOsSockLen();
    try std.posix.getsockname(socket.handle, &native.any, &address_length);
    return ipv4.Ipv4Address.from_native(native);
}

test "TCP connections complete nonblocking loopback handshakes and close" {
    var listener = try socket_backend.Socket.open(.tcp);
    defer listener.close();
    try ipv4.bind(&listener, ipv4.Ipv4Address.wildcard(0));
    try std.posix.listen(listener.handle, 1);
    const endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_address(&listener)).port);

    var connection = try TcpConnection.init();
    defer if (connection.state != .closed) connection.close();
    var state = try connection.start_connect(endpoint, 1_000);
    var elapsed_ms: u32 = 0;
    while (state == .connecting and elapsed_ms < 1_000) : (elapsed_ms += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
        state = try connection.complete(elapsed_ms);
    }
    try std.testing.expectEqual(TcpConnectionState.connected, state);
    connection.close();
    try std.testing.expectEqual(TcpConnectionState.closed, connection.state);
}

test "TCP connections reject invalid transitions and preserve cancellation and timeout states" {
    var connection = try TcpConnection.init();
    defer if (connection.state != .closed) connection.close();
    try std.testing.expectError(error.InvalidState, connection.complete(0));
    connection.state = .connecting;
    connection.timeout_ms = 1;
    try std.testing.expectError(error.TimedOut, connection.complete(1));
    try std.testing.expectEqual(TcpConnectionState.timed_out, connection.state);
    try std.testing.expect(connection.socket == null);

    var cancellable = try TcpConnection.init();
    defer if (cancellable.state != .closed) cancellable.close();
    cancellable.state = .connecting;
    try cancellable.cancel();
    try std.testing.expectEqual(TcpConnectionState.cancelled, cancellable.state);
    try std.testing.expect(cancellable.socket == null);
    try std.testing.expectError(error.Cancelled, cancellable.complete(0));
}
