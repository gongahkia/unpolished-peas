const std = @import("std");
const ipv4 = @import("ipv4.zig");
const socket_backend = @import("socket_backend.zig");
const tcp_connection = @import("tcp_connection.zig");
const tcp_listener = @import("tcp_listener.zig");
const udp_socket = @import("udp_socket.zig");

pub const max_socket_poll_targets: usize = 64;
pub const SocketPollError = error{ InvalidTimeout, EmptyRegistrations, EmptyInterest, TooManyTargets, InvalidTarget, PollFailed, WakeupFailed };

pub const SocketPollTarget = union(enum) {
    udp: *udp_socket.UdpSocket,
    tcp: *tcp_connection.TcpConnection,
    tcp_listener: *tcp_listener.TcpListener,
};

pub const SocketPollInterest = struct {
    readable: bool = true,
    writable: bool = false,
};

pub const SocketPollFailure = struct {
    socket_error: bool = false,
    socket_hangup: bool = false,
    invalid_socket: bool = false,
};

pub const SocketPollEvent = struct {
    readable: bool = false,
    writable: bool = false,
    failure: SocketPollFailure = .{},
};

pub const SocketPollRegistration = struct {
    target: SocketPollTarget,
    interest: SocketPollInterest = .{},
    event: SocketPollEvent = .{},
};

pub const SocketPollResult = struct {
    ready_count: usize = 0,
    timed_out: bool = false,
    cancelled: bool = false,
};

pub const SocketPoller = struct {
    wakeup_reader: socket_backend.Socket,
    wakeup_writer: socket_backend.Socket,
    wakeup_destination: ipv4.Ipv4Address,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wait_lock: std.Thread.Mutex = .{},
    descriptors: [max_socket_poll_targets + 1]std.posix.pollfd = undefined,

    pub fn init() SocketPollError!SocketPoller {
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

    pub fn wait(self: *SocketPoller, registrations: []SocketPollRegistration, timeout_ms: i32) SocketPollError!SocketPollResult {
        if (timeout_ms < -1) return error.InvalidTimeout;
        if (registrations.len == 0) return error.EmptyRegistrations;
        if (registrations.len > max_socket_poll_targets) return error.TooManyTargets;
        self.wait_lock.lock();
        defer self.wait_lock.unlock();
        if (try self.consume_cancellation()) return .{ .cancelled = true };

        for (registrations, 0..) |*registration, index| {
            if (!registration.interest.readable and !registration.interest.writable) return error.EmptyInterest;
            var events: i16 = 0;
            if (registration.interest.readable) events |= std.posix.POLL.IN;
            if (registration.interest.writable) events |= std.posix.POLL.OUT;
            registration.event = .{};
            self.descriptors[index] = .{
                .fd = try target_handle(registration.target),
                .events = events,
                .revents = 0,
            };
        }
        self.descriptors[registrations.len] = .{
            .fd = self.wakeup_reader.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        const ready_count = std.posix.poll(self.descriptors[0 .. registrations.len + 1], timeout_ms) catch return error.PollFailed;
        if (ready_count == 0) return .{ .timed_out = true };
        const wakeup_events = self.descriptors[registrations.len].revents;
        if (wakeup_events & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) return error.WakeupFailed;

        var result = SocketPollResult{
            .cancelled = if (wakeup_events & std.posix.POLL.IN != 0) try self.consume_cancellation() else false,
        };
        for (registrations, 0..) |*registration, index| {
            const events = self.descriptors[index].revents;
            registration.event = .{
                .readable = events & std.posix.POLL.IN != 0,
                .writable = events & std.posix.POLL.OUT != 0,
                .failure = .{
                    .socket_error = events & std.posix.POLL.ERR != 0,
                    .socket_hangup = events & std.posix.POLL.HUP != 0,
                    .invalid_socket = events & std.posix.POLL.NVAL != 0,
                },
            };
            if (registration.event.readable or registration.event.writable or registration.event.failure.socket_error or registration.event.failure.socket_hangup or registration.event.failure.invalid_socket) result.ready_count += 1;
        }
        return result;
    }

    pub fn cancel(self: *SocketPoller) SocketPollError!void {
        if (self.cancelled.swap(true, .acq_rel)) return;
        const destination = self.wakeup_destination.to_native();
        _ = std.posix.sendto(self.wakeup_writer.handle, &[_]u8{0}, 0, &destination.any, destination.getOsSockLen()) catch {
            self.cancelled.store(false, .release);
            return error.WakeupFailed;
        };
    }

    pub fn close(self: *SocketPoller) void {
        self.wakeup_reader.close();
        self.wakeup_writer.close();
        self.* = undefined;
    }

    fn consume_cancellation(self: *SocketPoller) SocketPollError!bool {
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

fn target_handle(target: SocketPollTarget) SocketPollError!std.posix.socket_t {
    return switch (target) {
        .udp => |socket| socket.socket.handle,
        .tcp => |connection| (connection.socket orelse return error.InvalidTarget).handle,
        .tcp_listener => |listener| (listener.socket orelse return error.InvalidTarget).handle,
    };
}

fn local_address(socket: *socket_backend.Socket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var address_length = native.getOsSockLen();
    try std.posix.getsockname(socket.handle, &native.any, &address_length);
    return ipv4.Ipv4Address.from_native(native);
}

const CancellationContext = struct {
    poller: *SocketPoller,
    registrations: []SocketPollRegistration,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?SocketPollError!SocketPollResult = null,
};

fn wait_for_cancellation(context: *CancellationContext) void {
    context.started.store(true, .release);
    context.result = context.poller.wait(context.registrations, -1);
}

test "unified socket poller drives UDP and TCP listener readiness" {
    var poller = try SocketPoller.init();
    defer poller.close();
    var udp = try udp_socket.UdpSocket.init(.{});
    defer udp.close();
    try udp.bind(ipv4.Ipv4Address.wildcard(0));
    var udp_registration = [_]SocketPollRegistration{.{ .target = .{ .udp = &udp } }};
    try std.testing.expect((try poller.wait(udp_registration[0..], 0)).timed_out);

    const endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_address(&udp.socket)).port);
    var sender = try udp_socket.UdpSocket.init(.{});
    defer sender.close();
    _ = try sender.send_to("ready", endpoint);
    const udp_result = try poller.wait(udp_registration[0..], 1_000);
    try std.testing.expectEqual(@as(usize, 1), udp_result.ready_count);
    try std.testing.expect(udp_registration[0].event.readable);

    var listener = try tcp_listener.TcpListener.init(ipv4.Ipv4Address.wildcard(0), 1);
    defer listener.shutdown();
    const listener_endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    var client = try tcp_connection.TcpConnection.init();
    defer if (client.state != .closed) client.close();
    _ = try client.start_connect(listener_endpoint, 1_000);
    var client_registration = [_]SocketPollRegistration{.{
        .target = .{ .tcp = &client },
        .interest = .{ .readable = false, .writable = true },
    }};
    const client_result = try poller.wait(client_registration[0..], 1_000);
    try std.testing.expectEqual(@as(usize, 1), client_result.ready_count);
    try std.testing.expect(client_registration[0].event.writable);
    var listener_registration = [_]SocketPollRegistration{.{ .target = .{ .tcp_listener = &listener } }};
    const listener_result = try poller.wait(listener_registration[0..], 1_000);
    try std.testing.expectEqual(@as(usize, 1), listener_result.ready_count);
    try std.testing.expect(listener_registration[0].event.readable);
}

test "unified socket poller cancellation wakes an infinite wait" {
    var poller = try SocketPoller.init();
    defer poller.close();
    var socket = try udp_socket.UdpSocket.init(.{});
    defer socket.close();
    var registrations = [_]SocketPollRegistration{.{ .target = .{ .udp = &socket } }};
    var context = CancellationContext{ .poller = &poller, .registrations = registrations[0..] };
    var thread = try std.Thread.spawn(.{}, wait_for_cancellation, .{&context});
    while (!context.started.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);
    try poller.cancel();
    thread.join();
    try std.testing.expect(((context.result orelse unreachable) catch unreachable).cancelled);
}

test "unified socket poller rejects invalid registrations" {
    var poller = try SocketPoller.init();
    defer poller.close();
    var socket = try udp_socket.UdpSocket.init(.{});
    defer socket.close();
    var empty_interest = [_]SocketPollRegistration{.{
        .target = .{ .udp = &socket },
        .interest = .{ .readable = false, .writable = false },
    }};
    try std.testing.expectError(error.EmptyRegistrations, poller.wait(&.{}, 0));
    try std.testing.expectError(error.EmptyInterest, poller.wait(empty_interest[0..], 0));
}
