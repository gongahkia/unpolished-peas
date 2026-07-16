const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const socket_backend = @import("socket_backend.zig");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");
const endpoint_selection = @import("endpoint_selection.zig");

pub const SocketKind = socket_backend.SocketKind;
pub const SocketPlatform = socket_backend.SocketPlatform;
pub const SocketError = socket_backend.SocketError;
pub const Socket = socket_backend.Socket;
pub const open_with_family = socket_backend.Socket.open_with_family;
pub const native_platform = socket_backend.native_platform;
pub const map_platform_error = socket_backend.map_platform_error;
pub const Ipv4Error = ipv4.Ipv4Error;
pub const Ipv4Address = ipv4.Ipv4Address;
pub const bind = ipv4.bind;
pub const Ipv6Error = ipv6.Ipv6Error;
pub const Ipv6Address = ipv6.Ipv6Address;
pub const bind_ipv6 = ipv6.bind;
pub const EndpointMode = endpoint_selection.EndpointMode;
pub const PlatformSupport = endpoint_selection.PlatformSupport;
pub const EndpointSelectionError = endpoint_selection.EndpointSelectionError;
pub const select_endpoint_mode = endpoint_selection.select_endpoint_mode;
pub const package_name = "transport";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
}

test "transport package boundary" {
    try @import("std").testing.expectEqualStrings("transport", package_name);
}

test {
    _ = @import("socket_backend.zig");
    _ = @import("ipv4.zig");
    _ = @import("ipv6.zig");
    _ = @import("endpoint_selection.zig");
}
