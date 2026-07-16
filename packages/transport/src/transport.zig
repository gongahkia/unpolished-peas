const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const socket_backend = @import("socket_backend.zig");
const ipv4 = @import("ipv4.zig");

pub const SocketKind = socket_backend.SocketKind;
pub const SocketPlatform = socket_backend.SocketPlatform;
pub const SocketError = socket_backend.SocketError;
pub const Socket = socket_backend.Socket;
pub const native_platform = socket_backend.native_platform;
pub const map_platform_error = socket_backend.map_platform_error;
pub const Ipv4Error = ipv4.Ipv4Error;
pub const Ipv4Address = ipv4.Ipv4Address;
pub const bind = ipv4.bind;
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
}
