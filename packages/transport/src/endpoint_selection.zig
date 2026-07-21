const std = @import("std");
const endpoint = @import("endpoint.zig");
const hostname_resolution = @import("hostname_resolution.zig");
const socket_backend = @import("socket_backend.zig");

pub const EndpointMode = enum {
    ipv4,
    ipv6,
    dual_stack,
};

pub const PlatformSupport = struct {
    ipv4: bool,
    ipv6: bool,
    dual_stack: bool,
};

pub const SocketAddressFamily = enum {
    ipv4,
    ipv6,

    pub fn native(self: SocketAddressFamily) u32 {
        return switch (self) {
            .ipv4 => std.posix.AF.INET,
            .ipv6 => std.posix.AF.INET6,
        };
    }
};

pub const AddressFamilyPolicy = enum {
    ipv4_only,
    ipv6_only,
    prefer_ipv4,
    prefer_ipv6,
};

pub const DialRoute = struct {
    family: SocketAddressFamily,
    address: hostname_resolution.ResolvedAddress,

    pub fn open(self: DialRoute, kind: socket_backend.SocketKind) socket_backend.SocketError!socket_backend.Socket {
        return socket_backend.Socket.open_with_family(kind, self.family.native());
    }
};

pub const ListenRoute = struct {
    family: SocketAddressFamily,
    dual_stack: bool,

    pub fn open(self: ListenRoute, kind: socket_backend.SocketKind) socket_backend.SocketError!socket_backend.Socket {
        return socket_backend.Socket.open_with_family(kind, self.family.native());
    }
};

pub const EndpointSelectionError = error{ EndpointModeUnsupported, InvalidEndpoint, ResolutionResultsTooLarge, NoReachableAddress };

pub fn select_endpoint_mode(requested: EndpointMode, support: PlatformSupport) EndpointSelectionError!EndpointMode {
    return switch (requested) {
        .ipv4 => if (support.ipv4) .ipv4 else error.EndpointModeUnsupported,
        .ipv6 => if (support.ipv6) .ipv6 else error.EndpointModeUnsupported,
        .dual_stack => if (support.ipv4 and support.ipv6 and support.dual_stack) .dual_stack else error.EndpointModeUnsupported,
    };
}

pub fn select_dial_route(value: endpoint.Endpoint, resolved: []const hostname_resolution.ResolvedAddress, policy: AddressFamilyPolicy, support: PlatformSupport) EndpointSelectionError!DialRoute {
    if (!value.is_valid() or value.kind == .provider) return error.InvalidEndpoint;
    if (resolved.len > hostname_resolution.max_hostname_addresses) return error.ResolutionResultsTooLarge;
    return switch (value.kind) {
        .ipv4 => select_literal_route(.{ .ipv4 = value.to_ipv4() orelse return error.InvalidEndpoint }, policy, support),
        .ipv6 => select_literal_route(.{ .ipv6 = value.to_ipv6() orelse return error.InvalidEndpoint }, policy, support),
        .dns => select_resolved_route(resolved, value.port, policy, support),
        .provider => error.InvalidEndpoint,
    };
}

pub fn select_listen_route(requested: EndpointMode, support: PlatformSupport) EndpointSelectionError!ListenRoute {
    return switch (try select_endpoint_mode(requested, support)) {
        .ipv4 => .{ .family = .ipv4, .dual_stack = false },
        .ipv6 => .{ .family = .ipv6, .dual_stack = false },
        .dual_stack => .{ .family = .ipv6, .dual_stack = true },
    };
}

fn select_literal_route(address: hostname_resolution.ResolvedAddress, policy: AddressFamilyPolicy, support: PlatformSupport) EndpointSelectionError!DialRoute {
    const family = family_of(address);
    if (!permits(policy, family) or !supported(support, family)) return error.NoReachableAddress;
    return .{ .family = family, .address = address };
}

fn select_resolved_route(resolved: []const hostname_resolution.ResolvedAddress, port: u16, policy: AddressFamilyPolicy, support: PlatformSupport) EndpointSelectionError!DialRoute {
    const first = switch (policy) {
        .ipv4_only, .prefer_ipv4 => SocketAddressFamily.ipv4,
        .ipv6_only, .prefer_ipv6 => .ipv6,
    };
    const second: ?SocketAddressFamily = switch (policy) {
        .ipv4_only, .ipv6_only => null,
        .prefer_ipv4 => .ipv6,
        .prefer_ipv6 => .ipv4,
    };
    if (select_family_route(resolved, port, first, support)) |route| return route;
    if (second) |family| if (select_family_route(resolved, port, family, support)) |route| return route;
    return error.NoReachableAddress;
}

fn select_family_route(resolved: []const hostname_resolution.ResolvedAddress, port: u16, family: SocketAddressFamily, support: PlatformSupport) ?DialRoute {
    if (!supported(support, family)) return null;
    for (resolved) |address| {
        if (family_of(address) != family) continue;
        return .{ .family = family, .address = with_port(address, port) };
    }
    return null;
}

fn family_of(address: hostname_resolution.ResolvedAddress) SocketAddressFamily {
    return switch (address) {
        .ipv4 => .ipv4,
        .ipv6 => .ipv6,
    };
}

fn with_port(address: hostname_resolution.ResolvedAddress, port: u16) hostname_resolution.ResolvedAddress {
    return switch (address) {
        .ipv4 => |value| .{ .ipv4 = .{ .octets = value.octets, .port = port } },
        .ipv6 => |value| .{ .ipv6 = .{ .octets = value.octets, .port = port, .scope_id = value.scope_id } },
    };
}

fn permits(policy: AddressFamilyPolicy, family: SocketAddressFamily) bool {
    return switch (policy) {
        .ipv4_only => family == .ipv4,
        .ipv6_only => family == .ipv6,
        .prefer_ipv4, .prefer_ipv6 => true,
    };
}

fn supported(support: PlatformSupport, family: SocketAddressFamily) bool {
    return switch (family) {
        .ipv4 => support.ipv4,
        .ipv6 => support.ipv6,
    };
}

test "endpoint selection preserves explicit IPv4 IPv6 and dual-stack requests" {
    const support = PlatformSupport{ .ipv4 = true, .ipv6 = true, .dual_stack = true };
    try std.testing.expectEqual(EndpointMode.ipv4, try select_endpoint_mode(.ipv4, support));
    try std.testing.expectEqual(EndpointMode.ipv6, try select_endpoint_mode(.ipv6, support));
    try std.testing.expectEqual(EndpointMode.dual_stack, try select_endpoint_mode(.dual_stack, support));
}

test "endpoint selection rejects unavailable platform modes" {
    try std.testing.expectError(error.EndpointModeUnsupported, select_endpoint_mode(.ipv6, .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }));
    try std.testing.expectError(error.EndpointModeUnsupported, select_endpoint_mode(.dual_stack, .{ .ipv4 = true, .ipv6 = true, .dual_stack = false }));
}

test "dual-stack DNS routes prefer a reachable policy family" {
    const endpoint_value = try endpoint.Endpoint.from_hostname("dual-stack.example.test", 443);
    const resolved = [_]hostname_resolution.ResolvedAddress{
        .{ .ipv4 = .{ .octets = .{ 192, 0, 2, 1 }, .port = 1 } },
        .{ .ipv6 = .{ .octets = .{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 11 ++ .{1}, .port = 1, .scope_id = 0 } },
    };
    const dual_stack = PlatformSupport{ .ipv4 = true, .ipv6 = true, .dual_stack = true };
    const preferred = try select_dial_route(endpoint_value, resolved[0..], .prefer_ipv6, dual_stack);
    try std.testing.expectEqual(SocketAddressFamily.ipv6, preferred.family);
    switch (preferred.address) {
        .ipv4 => unreachable,
        .ipv6 => |address| try std.testing.expectEqual(@as(u16, 443), address.port),
    }
    const fallback = try select_dial_route(endpoint_value, resolved[0..], .prefer_ipv6, .{ .ipv4 = true, .ipv6 = false, .dual_stack = false });
    try std.testing.expectEqual(SocketAddressFamily.ipv4, fallback.family);
    try std.testing.expectError(error.NoReachableAddress, select_dial_route(endpoint_value, resolved[0..], .ipv6_only, .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }));
}

test "selected dial and listener routes open the selected socket family" {
    const support = PlatformSupport{ .ipv4 = true, .ipv6 = true, .dual_stack = true };
    const endpoint_value = endpoint.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 9000 });
    const dial = try select_dial_route(endpoint_value, &.{}, .prefer_ipv6, support);
    try std.testing.expectEqual(SocketAddressFamily.ipv4, dial.family);
    var dial_socket = try dial.open(.udp);
    defer dial_socket.close();
    const listen = try select_listen_route(.dual_stack, support);
    try std.testing.expectEqual(SocketAddressFamily.ipv6, listen.family);
    try std.testing.expect(listen.dual_stack);
    var listen_socket = try listen.open(.tcp);
    defer listen_socket.close();
}
