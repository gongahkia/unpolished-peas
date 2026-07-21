const std = @import("std");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");

pub const UdpListenerError = std.mem.Allocator.Error || resource.HandleError || transport.EndpointSelectionError || transport.SocketError || transport.SocketOptionError || transport.Ipv4Error || transport.Ipv6Error || error{ InvalidConfiguration, InvalidEndpoint, InvalidRoute, ListenerCapacityExceeded, UnknownListener, PollFailed };

pub const UdpListenerConfig = struct {
    endpoint: transport.Endpoint,
    mode: transport.EndpointMode = .ipv4,
    platform_support: transport.PlatformSupport = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false },
    socket_options: transport.SocketOptionConfig = .{},

    pub fn route(self: UdpListenerConfig) UdpListenerError!transport.ListenRoute {
        if (!self.endpoint.is_valid()) return error.InvalidEndpoint;
        const selected = try transport.select_listen_route(self.mode, self.platform_support);
        return switch (self.endpoint.kind) {
            .ipv4 => if (selected.family == .ipv4 and !selected.dual_stack and self.endpoint.to_ipv4() != null) selected else error.InvalidRoute,
            .ipv6 => if (selected.family == .ipv6 and self.endpoint.to_ipv6() != null) selected else error.InvalidRoute,
            .dns, .provider => error.InvalidEndpoint,
        };
    }
};

pub const UdpListenerPoll = struct {
    readable: bool = false,
    socket_error: bool = false,
    socket_hangup: bool = false,
    invalid_socket: bool = false,
};

pub const UdpListenerReadiness = struct {
    listener: *resource.ResourceHandle,
    poll: UdpListenerPoll,
};

const Entry = struct {
    handle: *resource.ResourceHandle,
    socket: transport.Socket,
    route: transport.ListenRoute,
};

pub const UdpListenerRegistry = struct {
    allocator: std.mem.Allocator,
    resources: *resource.ResourceRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    readiness_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, resources: *resource.ResourceRegistry, capacity: usize) UdpListenerError!UdpListenerRegistry {
        if (capacity == 0 or capacity > resources.slots.len) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .resources = resources, .capacity = capacity };
    }

    pub fn deinit(self: *UdpListenerRegistry) void {
        for (self.entries.items) |*entry| {
            entry.socket.close();
            self.resources.release_kind(entry.handle, .listener) catch {};
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *UdpListenerRegistry, config: UdpListenerConfig) UdpListenerError!*resource.ResourceHandle {
        const route = try config.route();
        if (self.entries.items.len >= self.capacity) return error.ListenerCapacityExceeded;
        const handle = try self.resources.acquire_kind(.listener);
        errdefer self.resources.release_kind(handle, .listener) catch {};
        var socket = try route.open(.udp);
        errdefer socket.close();
        if (route.dual_stack and config.socket_options.ipv6_only == true) return error.InvalidRoute;
        if (route.dual_stack) try enable_dual_stack(&socket);
        try transport.apply_socket_options(&socket, config.socket_options);
        switch (config.endpoint.kind) {
            .ipv4 => try transport.bind(&socket, config.endpoint.to_ipv4() orelse return error.InvalidEndpoint),
            .ipv6 => try transport.bind_ipv6(&socket, config.endpoint.to_ipv6() orelse return error.InvalidEndpoint),
            .dns, .provider => return error.InvalidEndpoint,
        }
        try self.entries.append(self.allocator, .{ .handle = handle, .socket = socket, .route = route });
        return handle;
    }

    pub fn poll(self: *UdpListenerRegistry, handle: *resource.ResourceHandle) UdpListenerError!UdpListenerPoll {
        const entry = try self.lookup(handle);
        return poll_socket(&entry.socket);
    }

    pub fn pollNextReadiness(self: *UdpListenerRegistry) UdpListenerError!?UdpListenerReadiness {
        if (self.entries.items.len == 0) return null;
        var index = if (self.readiness_cursor < self.entries.items.len) self.readiness_cursor else 0;
        var checked: usize = 0;
        while (checked < self.entries.items.len) : (checked += 1) {
            const entry = &self.entries.items[index];
            const result = try poll_socket(&entry.socket);
            index = next_index(index, self.entries.items.len);
            if (!result.readable and !result.socket_error and !result.socket_hangup and !result.invalid_socket) continue;
            self.readiness_cursor = index;
            return .{ .listener = entry.handle, .poll = result };
        }
        self.readiness_cursor = index;
        return null;
    }

    pub fn localAddress(self: *UdpListenerRegistry, handle: *resource.ResourceHandle) UdpListenerError!transport.ResolvedAddress {
        const entry = try self.lookup(handle);
        return switch (entry.route.family) {
            .ipv4 => {
                var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                var length = native.getOsSockLen();
                std.posix.getsockname(entry.socket.handle, &native.any, &length) catch return error.PollFailed;
                return .{ .ipv4 = transport.Ipv4Address.from_native(native) catch return error.InvalidRoute };
            },
            .ipv6 => {
                var native = std.net.Address.initIp6(.{0} ** 16, 0, 0, 0);
                var length = native.getOsSockLen();
                std.posix.getsockname(entry.socket.handle, &native.any, &length) catch return error.PollFailed;
                return .{ .ipv6 = transport.Ipv6Address.from_native(native) catch return error.InvalidRoute };
            },
        };
    }

    pub fn close(self: *UdpListenerRegistry, handle: *resource.ResourceHandle) UdpListenerError!void {
        try self.resources.validate_kind(handle, .listener);
        for (self.entries.items, 0..) |_, index| {
            if (self.entries.items[index].handle != handle) continue;
            var entry = self.entries.orderedRemove(index);
            entry.socket.close();
            try self.resources.release_kind(handle, .listener);
            return;
        }
        return error.UnknownListener;
    }

    fn lookup(self: *UdpListenerRegistry, handle: *resource.ResourceHandle) UdpListenerError!*Entry {
        try self.resources.validate_kind(handle, .listener);
        for (self.entries.items) |*entry| if (entry.handle == handle) return entry;
        return error.UnknownListener;
    }
};

fn poll_socket(socket: *transport.Socket) UdpListenerError!UdpListenerPoll {
    var descriptors = [_]std.posix.pollfd{.{ .fd = socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = std.posix.poll(&descriptors, 0) catch return error.PollFailed;
    const events = descriptors[0].revents;
    return .{
        .readable = events & std.posix.POLL.IN != 0,
        .socket_error = events & std.posix.POLL.ERR != 0,
        .socket_hangup = events & std.posix.POLL.HUP != 0,
        .invalid_socket = events & std.posix.POLL.NVAL != 0,
    };
}

fn next_index(index: usize, len: usize) usize {
    return if (index + 1 == len) 0 else index + 1;
}

fn enable_dual_stack(socket: *transport.Socket) UdpListenerError!void {
    const disabled: c_int = 0;
    const option: u32 = if (@import("builtin").os.tag == .linux) 26 else 27;
    std.posix.setsockopt(socket.handle, 41, option, std.mem.asBytes(&disabled)) catch return error.InvalidRoute;
}

test "UDP listener registries bind poll and release runtime listener handles" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 1);
        defer resources.deinit();
        var listeners = try UdpListenerRegistry.init(allocator, &resources, 1);
        defer listeners.deinit();
        const handle = try listeners.open(.{ .endpoint = transport.Endpoint.from_ipv4(transport.Ipv4Address.wildcard(0)) });
        const local = try listeners.localAddress(handle);
        switch (local) {
            .ipv4 => |address| try std.testing.expect(address.port != 0),
            .ipv6 => unreachable,
        }
        try std.testing.expect(!(try listeners.poll(handle)).readable);
        try listeners.close(handle);
        try std.testing.expectError(error.StaleHandle, listeners.poll(handle));
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "UDP listener registries enforce selected route and listener capacity" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var listeners = try UdpListenerRegistry.init(std.testing.allocator, &resources, 1);
    defer listeners.deinit();
    const endpoint = transport.Endpoint.from_ipv4(transport.Ipv4Address.wildcard(0));
    try std.testing.expectError(error.InvalidRoute, listeners.open(.{ .endpoint = endpoint, .mode = .ipv6, .platform_support = .{ .ipv4 = true, .ipv6 = true, .dual_stack = false } }));
    _ = try listeners.open(.{ .endpoint = endpoint });
    try std.testing.expectError(error.ListenerCapacityExceeded, listeners.open(.{ .endpoint = endpoint }));
}

test "UDP listener registries reject unsupported socket policy before retaining handles" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var listeners = try UdpListenerRegistry.init(std.testing.allocator, &resources, 1);
    defer listeners.deinit();
    const endpoint = transport.Endpoint.from_ipv4(transport.Ipv4Address.wildcard(0));
    try std.testing.expectError(error.UnsupportedOption, listeners.open(.{ .endpoint = endpoint, .socket_options = .{ .ipv6_only = true } }));
    const handle = try listeners.open(.{ .endpoint = endpoint, .socket_options = .{ .reuse_address = true, .receive_buffer_bytes = 4_096, .send_buffer_bytes = 4_096, .ecn = .optional } });
    try listeners.close(handle);
}
