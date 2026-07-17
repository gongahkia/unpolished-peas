const std = @import("std");
const buffer_pool = @import("buffer_pool.zig");
const hostname_resolution = @import("hostname_resolution.zig");
const socket_poller = @import("socket_poller.zig");
const tcp_flow_control = @import("tcp_flow_control.zig");
const udp_socket = @import("udp_socket.zig");

test "transport resources report bounded descriptor queue buffer and resolver exhaustion" {
    var socket = try udp_socket.UdpSocket.init(.{});
    defer socket.close();
    var poller = try socket_poller.SocketPoller.init();
    defer poller.close();
    var registrations: [socket_poller.max_socket_poll_targets + 1]socket_poller.SocketPollRegistration = undefined;
    for (&registrations) |*registration| registration.* = .{ .target = .{ .udp = &socket } };
    try std.testing.expectError(error.TooManyTargets, poller.wait(registrations[0..], 0));

    var flow = try tcp_flow_control.TcpFlowController.init(.{ .maximum_queued_bytes = 1 });
    try flow.reserve_write(1);
    try std.testing.expectError(error.WriteQueueFull, flow.reserve_write(1));

    var pool = try buffer_pool.PacketBufferPool.init(std.testing.allocator, .{
        .packet_capacity = 1,
        .pooled_buffers = 1,
        .fallback_buffers = 0,
    });
    defer pool.deinit();
    var lease = try pool.acquire();
    defer pool.release(&lease) catch unreachable;
    try std.testing.expectError(error.Exhausted, pool.acquire());

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    try std.testing.expectError(error.OutOfMemory, hostname_resolution.HostnameResolution.init(fixed.allocator(), "localhost", 1));
}

test "transport cancellation wakeups coalesce without unbounded signals" {
    var socket = try udp_socket.UdpSocket.init(.{});
    defer socket.close();
    var poller = try socket_poller.SocketPoller.init();
    defer poller.close();
    var registrations = [_]socket_poller.SocketPollRegistration{.{ .target = .{ .udp = &socket } }};
    try poller.cancel();
    try poller.cancel();
    try std.testing.expect((try poller.wait(registrations[0..], 0)).cancelled);
    try poller.cancel();
    try std.testing.expect((try poller.wait(registrations[0..], 0)).cancelled);
}
