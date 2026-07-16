const std = @import("std");

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

pub const EndpointSelectionError = error{EndpointModeUnsupported};

pub fn select_endpoint_mode(requested: EndpointMode, support: PlatformSupport) EndpointSelectionError!EndpointMode {
    return switch (requested) {
        .ipv4 => if (support.ipv4) .ipv4 else error.EndpointModeUnsupported,
        .ipv6 => if (support.ipv6) .ipv6 else error.EndpointModeUnsupported,
        .dual_stack => if (support.ipv4 and support.ipv6 and support.dual_stack) .dual_stack else error.EndpointModeUnsupported,
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
