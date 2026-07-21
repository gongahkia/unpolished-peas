const std = @import("std");
const ipv4 = @import("ipv4.zig");
const socket_backend = @import("socket_backend.zig");
const tcp_connection = @import("tcp_connection.zig");

pub const TcpListenerState = enum {
    listening,
    closed,
};

pub const TcpListenerError = error{ NotListening, ListenFailed, WouldBlock, AcceptFailed, PeerAddressInvalid };

pub const TcpAdmission = enum {
    allow,
    reject,
};

pub const TcpPendingConnection = struct {
    socket: socket_backend.Socket,
    peer: ipv4.Ipv4Address,

    pub fn close(self: *TcpPendingConnection) void {
        self.socket.close();
        self.* = undefined;
    }
};

pub const TcpAdmittedConnection = struct {
    connection: tcp_connection.TcpConnection,
    peer: ipv4.Ipv4Address,
};

pub const TcpListener = struct {
    socket: ?socket_backend.Socket,
    state: TcpListenerState = .listening,

    pub fn init(address: ipv4.Ipv4Address, backlog: u31) TcpListenerError!TcpListener {
        var socket = socket_backend.Socket.open(.tcp) catch return error.ListenFailed;
        errdefer socket.close();
        ipv4.bind(&socket, address) catch return error.ListenFailed;
        std.posix.listen(socket.handle, backlog) catch return error.ListenFailed;
        return .{ .socket = socket };
    }

    pub fn local_address(self: *TcpListener) TcpListenerError!ipv4.Ipv4Address {
        const socket = self.socket orelse return error.NotListening;
        var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var address_length = native.getOsSockLen();
        std.posix.getsockname(socket.handle, &native.any, &address_length) catch return error.ListenFailed;
        return ipv4.Ipv4Address.from_native(native) catch error.PeerAddressInvalid;
    }

    pub fn accept(self: *TcpListener) TcpListenerError!TcpPendingConnection {
        const socket = self.socket orelse return error.NotListening;
        var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var peer_length = native.getOsSockLen();
        const handle = std.posix.accept(socket.handle, &native.any, &peer_length, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            else => error.AcceptFailed,
        };
        var accepted = socket_backend.Socket{ .handle = handle, .kind = .tcp, .family = std.posix.AF.INET };
        errdefer accepted.close();
        return .{
            .socket = accepted,
            .peer = ipv4.Ipv4Address.from_native(native) catch return error.PeerAddressInvalid,
        };
    }

    pub fn admit(_: *TcpListener, pending: *TcpPendingConnection, admission: TcpAdmission) ?TcpAdmittedConnection {
        if (admission == .reject) {
            pending.close();
            return null;
        }
        const admitted = TcpAdmittedConnection{
            .connection = .{ .socket = pending.socket, .state = .connected },
            .peer = pending.peer,
        };
        pending.* = undefined;
        return admitted;
    }

    pub fn shutdown(self: *TcpListener) void {
        if (self.socket) |*socket| {
            std.posix.shutdown(socket.handle, .both) catch {};
            socket.close();
            self.socket = null;
        }
        self.state = .closed;
    }
};

fn accept_with_retry(listener: *TcpListener) !TcpPendingConnection {
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

test "TCP listeners accept peer-addressed connections and apply admission decisions" {
    var listener = try TcpListener.init(ipv4.Ipv4Address.wildcard(0), 2);
    defer listener.shutdown();
    const endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    try std.testing.expectError(error.WouldBlock, listener.accept());

    var client = try tcp_connection.TcpConnection.init();
    defer if (client.state != .closed) client.close();
    _ = try client.start_connect(endpoint, 1_000);
    var pending = try accept_with_retry(&listener);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, pending.peer.octets);
    var admitted = listener.admit(&pending, .allow) orelse unreachable;
    defer admitted.connection.close();
    try std.testing.expectEqual(tcp_connection.TcpConnectionState.connected, admitted.connection.state);

    var rejected_client = try tcp_connection.TcpConnection.init();
    defer if (rejected_client.state != .closed) rejected_client.close();
    _ = try rejected_client.start_connect(endpoint, 1_000);
    var rejected = try accept_with_retry(&listener);
    try std.testing.expect(listener.admit(&rejected, .reject) == null);
}

test "TCP listener shutdown prevents later accept attempts" {
    var listener = try TcpListener.init(ipv4.Ipv4Address.wildcard(0), 1);
    listener.shutdown();
    try std.testing.expectEqual(TcpListenerState.closed, listener.state);
    try std.testing.expectError(error.NotListening, listener.accept());
}
