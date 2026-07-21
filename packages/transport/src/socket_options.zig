const std = @import("std");
const builtin = @import("builtin");
const socket_backend = @import("socket_backend.zig");

pub const SocketOptionError = error{ InvalidBufferSize, NoDelayRequiresTcp, UnsupportedOption, ApplyFailed };

pub const SocketEcnPolicy = enum {
    disabled,
    optional,
    required,
};

pub const SocketOptionConfig = struct {
    reuse_address: ?bool = null,
    keepalive: ?bool = null,
    receive_buffer_bytes: ?u32 = null,
    send_buffer_bytes: ?u32 = null,
    no_delay: ?bool = null,
    ipv6_only: ?bool = null,
    ecn: SocketEcnPolicy = .disabled,
};

pub fn apply_socket_options(socket: *socket_backend.Socket, config: SocketOptionConfig) SocketOptionError!void {
    if (config.receive_buffer_bytes) |bytes| if (bytes == 0) return error.InvalidBufferSize;
    if (config.send_buffer_bytes) |bytes| if (bytes == 0) return error.InvalidBufferSize;
    if (config.no_delay != null and socket.kind != .tcp) return error.NoDelayRequiresTcp;
    if (config.ipv6_only != null and (socket.kind != .udp or socket.family != std.posix.AF.INET6)) return error.UnsupportedOption;
    if (config.reuse_address) |enabled| try set_bool(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, enabled);
    if (config.keepalive) |enabled| try set_bool(socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, enabled);
    if (config.receive_buffer_bytes) |bytes| try set_int(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, bytes);
    if (config.send_buffer_bytes) |bytes| try set_int(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, bytes);
    if (config.no_delay) |enabled| try set_bool(socket, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, enabled);
    if (config.ipv6_only) |enabled| try set_bool(socket, 41, ipv6_v6only_option() orelse return error.UnsupportedOption, enabled);
    try apply_ecn(socket, config.ecn);
}

fn apply_ecn(socket: *socket_backend.Socket, policy: SocketEcnPolicy) SocketOptionError!void {
    if (policy == .disabled) return;
    const option = ecn_option(socket.family) orelse {
        if (policy == .optional) return;
        return error.UnsupportedOption;
    };
    set_int(socket, option.level, option.name, 2) catch |err| switch (err) {
        error.UnsupportedOption => if (policy == .optional) return else return err,
        else => return err,
    };
}

fn ipv6_v6only_option() ?u32 {
    return switch (builtin.os.tag) {
        .linux => 26,
        .macos, .windows => 27,
        else => null,
    };
}

fn ecn_option(family: u32) ?struct { level: i32, name: u32 } {
    return switch (builtin.os.tag) {
        .linux => switch (family) {
            std.posix.AF.INET => .{ .level = 0, .name = 1 },
            std.posix.AF.INET6 => .{ .level = 41, .name = 67 },
            else => null,
        },
        .macos => switch (family) {
            std.posix.AF.INET => .{ .level = 0, .name = 3 },
            std.posix.AF.INET6 => .{ .level = 41, .name = 36 },
            else => null,
        },
        else => null,
    };
}

fn set_bool(socket: *socket_backend.Socket, level: i32, option: u32, enabled: bool) SocketOptionError!void {
    const value: c_int = @intFromBool(enabled);
    std.posix.setsockopt(socket.handle, level, option, &std.mem.toBytes(value)) catch |err| return map_option_error(err);
}

fn set_int(socket: *socket_backend.Socket, level: i32, option: u32, value: u32) SocketOptionError!void {
    const native: c_int = @intCast(value);
    std.posix.setsockopt(socket.handle, level, option, &std.mem.toBytes(native)) catch |err| return map_option_error(err);
}

fn map_option_error(err: anyerror) SocketOptionError {
    return switch (err) {
        error.InvalidProtocolOption, error.OperationNotSupported => error.UnsupportedOption,
        else => error.ApplyFailed,
    };
}

test "socket options apply explicit UDP reuse keepalive and buffer configuration" {
    var socket = try socket_backend.Socket.open(.udp);
    defer socket.close();
    try apply_socket_options(&socket, .{
        .reuse_address = true,
        .keepalive = true,
        .receive_buffer_bytes = 4_096,
        .send_buffer_bytes = 4_096,
    });
}

test "socket options apply TCP no-delay and validate unsupported configurations" {
    var tcp = try socket_backend.Socket.open(.tcp);
    defer tcp.close();
    try apply_socket_options(&tcp, .{ .no_delay = true });
    var udp = try socket_backend.Socket.open(.udp);
    defer udp.close();
    try std.testing.expectError(error.NoDelayRequiresTcp, apply_socket_options(&udp, .{ .no_delay = true }));
    try std.testing.expectError(error.InvalidBufferSize, apply_socket_options(&udp, .{ .receive_buffer_bytes = 0 }));
    try std.testing.expectError(error.UnsupportedOption, apply_socket_options(&udp, .{ .ipv6_only = true }));
}

test "socket options apply IPv6-only and ECN policy when supported" {
    var socket = try socket_backend.Socket.open_with_family(.udp, std.posix.AF.INET6);
    defer socket.close();
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        try apply_socket_options(&socket, .{ .ipv6_only = true, .ecn = .required });
    } else {
        try std.testing.expectError(error.UnsupportedOption, apply_socket_options(&socket, .{ .ecn = .required }));
    }
}
