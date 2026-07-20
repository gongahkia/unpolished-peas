const std = @import("std");
const builtin = @import("builtin");
const core = @import("minna-san-core");

pub const SocketKind = enum {
    udp,
    tcp,
};

pub const SocketPlatform = enum {
    posix,
    windows,
};

pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    InvalidPlatformConfiguration,
    PlatformFailure,
};

pub const Socket = struct {
    handle: std.posix.socket_t,
    kind: SocketKind,

    pub fn open(kind: SocketKind) SocketError!Socket {
        return open_with_family(kind, std.posix.AF.INET);
    }

    pub fn open_with_platform_config(kind: SocketKind, config: core.PlatformConfig) SocketError!Socket {
        config.validate() catch return error.InvalidPlatformConfiguration;
        return open(kind);
    }

    pub fn open_with_family(kind: SocketKind, family: u32) SocketError!Socket {
        const socket_type: u32 = switch (kind) {
            .udp => @as(u32, std.posix.SOCK.DGRAM),
            .tcp => @as(u32, std.posix.SOCK.STREAM),
        } | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
        const protocol: u32 = switch (kind) {
            .udp => @as(u32, std.posix.IPPROTO.UDP),
            .tcp => @as(u32, std.posix.IPPROTO.TCP),
        };
        const handle = std.posix.socket(family, socket_type, protocol) catch |err| return map_platform_error(err);
        return .{ .handle = handle, .kind = kind };
    }

    pub fn close(self: *Socket) void {
        if (builtin.os.tag == .windows) {
            std.os.windows.closesocket(self.handle) catch {};
        } else {
            std.posix.close(self.handle);
        }
        self.* = undefined;
    }
};

pub fn native_platform() SocketPlatform {
    return if (builtin.os.tag == .windows) .windows else .posix;
}

pub fn map_platform_error(err: anyerror) SocketError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.AddressFamilyNotSupported => error.AddressFamilyNotSupported,
        error.ProtocolFamilyNotAvailable => error.ProtocolFamilyNotAvailable,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.ProtocolNotSupported => error.ProtocolNotSupported,
        error.SocketTypeNotSupported => error.SocketTypeNotSupported,
        else => error.PlatformFailure,
    };
}

test "desktop socket backend opens nonblocking UDP and TCP primitives" {
    var udp = try Socket.open(.udp);
    defer udp.close();
    var tcp = try Socket.open(.tcp);
    defer tcp.close();
    try std.testing.expectEqual(SocketKind.udp, udp.kind);
    try std.testing.expectEqual(SocketKind.tcp, tcp.kind);
}

test "socket backend preserves known and unknown platform error classes" {
    try std.testing.expectEqual(error.AccessDenied, map_platform_error(error.AccessDenied));
    try std.testing.expectEqual(error.PlatformFailure, map_platform_error(error.Unexpected));
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(SocketPlatform.windows, native_platform());
    } else {
        try std.testing.expectEqual(SocketPlatform.posix, native_platform());
    }
}

test "socket backend rejects invalid platform configuration before opening" {
    try std.testing.expectError(error.InvalidPlatformConfiguration, Socket.open_with_platform_config(.udp, .{ .limits = .{ .session_capacity = 2, .channel_capacity = 1 } }));
}
