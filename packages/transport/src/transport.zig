const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const socket_backend = @import("socket_backend.zig");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");
const endpoint_selection = @import("endpoint_selection.zig");
const udp_socket = @import("udp_socket.zig");
const udp_readiness = @import("udp_readiness.zig");
const tcp_connection = @import("tcp_connection.zig");
const tcp_listener = @import("tcp_listener.zig");
const tcp_framed = @import("tcp_framed.zig");
const socket_poller = @import("socket_poller.zig");
const hostname_resolution = @import("hostname_resolution.zig");

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
pub const UdpSocketError = udp_socket.UdpSocketError;
pub const UdpDatagramError = udp_socket.UdpDatagramError;
pub const max_ipv4_datagram_bytes = udp_socket.max_ipv4_datagram_bytes;
pub const ReceivedDatagram = udp_socket.ReceivedDatagram;
pub const UdpSocketConfig = udp_socket.UdpSocketConfig;
pub const UdpSocket = udp_socket.UdpSocket;
pub const UdpReadinessError = udp_readiness.UdpReadinessError;
pub const UdpReadinessInterest = udp_readiness.UdpReadinessInterest;
pub const UdpReadinessFailure = udp_readiness.UdpReadinessFailure;
pub const UdpReadinessResult = udp_readiness.UdpReadinessResult;
pub const UdpReadiness = udp_readiness.UdpReadiness;
pub const TcpConnectionState = tcp_connection.TcpConnectionState;
pub const TcpConnectionError = tcp_connection.TcpConnectionError;
pub const TcpConnection = tcp_connection.TcpConnection;
pub const TcpListenerState = tcp_listener.TcpListenerState;
pub const TcpListenerError = tcp_listener.TcpListenerError;
pub const TcpAdmission = tcp_listener.TcpAdmission;
pub const TcpPendingConnection = tcp_listener.TcpPendingConnection;
pub const TcpAdmittedConnection = tcp_listener.TcpAdmittedConnection;
pub const TcpListener = tcp_listener.TcpListener;
pub const tcp_frame_header_bytes = tcp_framed.tcp_frame_header_bytes;
pub const TcpFrameError = tcp_framed.TcpFrameError;
pub const TcpFrameReader = tcp_framed.TcpFrameReader;
pub const TcpFrameWriter = tcp_framed.TcpFrameWriter;
pub const max_socket_poll_targets = socket_poller.max_socket_poll_targets;
pub const SocketPollError = socket_poller.SocketPollError;
pub const SocketPollTarget = socket_poller.SocketPollTarget;
pub const SocketPollInterest = socket_poller.SocketPollInterest;
pub const SocketPollFailure = socket_poller.SocketPollFailure;
pub const SocketPollEvent = socket_poller.SocketPollEvent;
pub const SocketPollRegistration = socket_poller.SocketPollRegistration;
pub const SocketPollResult = socket_poller.SocketPollResult;
pub const SocketPoller = socket_poller.SocketPoller;
pub const max_hostname_addresses = hostname_resolution.max_hostname_addresses;
pub const HostnameResolutionError = hostname_resolution.HostnameResolutionError;
pub const ResolvedAddress = hostname_resolution.ResolvedAddress;
pub const HostnameResolutionState = hostname_resolution.HostnameResolutionState;
pub const HostnameResolution = hostname_resolution.HostnameResolution;
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
    _ = @import("udp_socket.zig");
    _ = @import("udp_readiness.zig");
    _ = @import("tcp_connection.zig");
    _ = @import("tcp_listener.zig");
    _ = @import("tcp_framed.zig");
    _ = @import("socket_poller.zig");
    _ = @import("hostname_resolution.zig");
}
