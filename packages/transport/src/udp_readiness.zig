const std = @import("std");
const ipv4 = @import("ipv4.zig");
const socket_backend = @import("socket_backend.zig");
const udp_socket = @import("udp_socket.zig");

pub const UdpReadinessError = error{ InvalidTimeout, EmptyInterest, PollFailed, WakeupFailed };

pub const UdpReadinessInterest = struct {
    readable: bool = true,
    writable: bool = false,
};

pub const UdpReadinessFailure = struct {
    socket_error: bool = false,
    socket_hangup: bool = false,
    invalid_socket: bool = false,
};

pub const UdpReadinessResult = struct {
    readable: bool = false,
    writable: bool = false,
    timed_out: bool = false,
    cancelled: bool = false,
    failure: UdpReadinessFailure = .{},
};

pub const UdpReadiness = struct {
    wakeup_reader: socket_backend.Socket,
    wakeup_writer: socket_backend.Socket,
    wakeup_destination: ipv4.Ipv4Address,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wait_lock: std.Thread.Mutex = .{},

    pub fn init() UdpReadinessError!UdpReadiness {
        var wakeup_reader = socket_backend.Socket.open(.udp) catch return error.WakeupFailed;
        errdefer wakeup_reader.close();
        ipv4.bind(&wakeup_reader, ipv4.Ipv4Address.wildcard(0)) catch return error.WakeupFailed;
        const bound = local_address(&wakeup_reader) catch return error.WakeupFailed;
        var wakeup_writer = socket_backend.Socket.open(.udp) catch return error.WakeupFailed;
        errdefer wakeup_writer.close();
        return .{
            .wakeup_reader = wakeup_reader,
            .wakeup_writer = wakeup_writer,
            .wakeup_destination = ipv4.Ipv4Address.parse("127.0.0.1", bound.port) catch return error.WakeupFailed,
        };
    }

    pub fn wait(self: *UdpReadiness, socket: *udp_socket.UdpSocket, interest: UdpReadinessInterest, timeout_ms: i32) UdpReadinessError!UdpReadinessResult {
        if (timeout_ms < -1) return error.InvalidTimeout;
        if (!interest.readable and !interest.writable) return error.EmptyInterest;
        self.wait_lock.lock();
        defer self.wait_lock.unlock();
        if (try self.consume_cancellation()) return .{ .cancelled = true };

        var socket_events: i16 = 0;
        if (interest.readable) socket_events |= std.posix.POLL.IN;
        if (interest.writable) socket_events |= std.posix.POLL.OUT;
        var fds = [_]std.posix.pollfd{
            .{ .fd = socket.socket.handle, .events = socket_events, .revents = 0 },
            .{ .fd = self.wakeup_reader.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready_count = std.posix.poll(&fds, timeout_ms) catch return error.PollFailed;
        if (ready_count == 0) return .{ .timed_out = true };
        if (fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) return error.WakeupFailed;

        return .{
            .readable = fds[0].revents & std.posix.POLL.IN != 0,
            .writable = fds[0].revents & std.posix.POLL.OUT != 0,
            .cancelled = if (fds[1].revents & std.posix.POLL.IN != 0) try self.consume_cancellation() else false,
            .failure = .{
                .socket_error = fds[0].revents & std.posix.POLL.ERR != 0,
                .socket_hangup = fds[0].revents & std.posix.POLL.HUP != 0,
                .invalid_socket = fds[0].revents & std.posix.POLL.NVAL != 0,
            },
        };
    }

    pub fn cancel(self: *UdpReadiness) UdpReadinessError!void {
        if (self.cancelled.swap(true, .acq_rel)) return;
        const destination = self.wakeup_destination.to_native();
        _ = std.posix.sendto(self.wakeup_writer.handle, &[_]u8{0}, 0, &destination.any, destination.getOsSockLen()) catch {
            self.cancelled.store(false, .release);
            return error.WakeupFailed;
        };
    }

    pub fn close(self: *UdpReadiness) void {
        self.wakeup_reader.close();
        self.wakeup_writer.close();
        self.* = undefined;
    }

    fn consume_cancellation(self: *UdpReadiness) UdpReadinessError!bool {
        if (!self.cancelled.load(.acquire)) return false;
        var storage: [32]u8 = undefined;
        while (true) {
            _ = std.posix.recv(self.wakeup_reader.handle, storage[0..], 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return error.WakeupFailed,
            };
        }
        return self.cancelled.swap(false, .acq_rel);
    }
};

fn local_address(socket: *socket_backend.Socket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var address_length = native.getOsSockLen();
    try std.posix.getsockname(socket.handle, &native.any, &address_length);
    return ipv4.Ipv4Address.from_native(native);
}

const WaitContext = struct {
    poller: *UdpReadiness,
    socket: *udp_socket.UdpSocket,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?UdpReadinessError!UdpReadinessResult = null,
};

fn wait_for_cancellation(context: *WaitContext) void {
    context.started.store(true, .release);
    context.result = context.poller.wait(context.socket, .{}, -1);
}

test "UDP readiness reports readable datagrams and timeouts" {
    var poller = try UdpReadiness.init();
    defer poller.close();
    var receiver = try udp_socket.UdpSocket.init(.{});
    defer receiver.close();
    try receiver.bind(ipv4.Ipv4Address.wildcard(0));
    try std.testing.expect((try poller.wait(&receiver, .{}, 0)).timed_out);

    const receiver_address = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_address(&receiver.socket)).port);
    var sender = try udp_socket.UdpSocket.init(.{});
    defer sender.close();
    _ = try sender.send_to("ready", receiver_address);
    const result = try poller.wait(&receiver, .{}, 1_000);
    try std.testing.expect(result.readable);
    try std.testing.expect(!result.failure.socket_error);
}

test "UDP readiness cancellation wakes an infinite wait" {
    var poller = try UdpReadiness.init();
    defer poller.close();
    var socket = try udp_socket.UdpSocket.init(.{});
    defer socket.close();
    var context = WaitContext{ .poller = &poller, .socket = &socket };
    var thread = try std.Thread.spawn(.{}, wait_for_cancellation, .{&context});
    while (!context.started.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);
    try poller.cancel();
    thread.join();
    try std.testing.expect(((context.result orelse unreachable) catch unreachable).cancelled);
}

test "UDP readiness preserves socket failures alongside readiness results" {
    var poller = try UdpReadiness.init();
    defer poller.close();
    var socket = try udp_socket.UdpSocket.init(.{});
    std.posix.close(socket.socket.handle);
    defer socket = undefined;
    const result = try poller.wait(&socket, .{}, 0);
    try std.testing.expect(result.failure.invalid_socket);
}
