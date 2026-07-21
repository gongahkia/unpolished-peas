const std = @import("std");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");

pub const TcpListenerRegistryError = std.mem.Allocator.Error || resource.HandleError || transport.TcpListenerError || error{ InvalidConfiguration, ListenerCapacityExceeded, UnknownListener, PollFailed };

pub const TcpListenerConfig = struct {
    endpoint: transport.Ipv4Address,
    backlog: u31 = 128,

    pub fn validate(self: TcpListenerConfig) TcpListenerRegistryError!void {
        if (self.backlog == 0) return error.InvalidConfiguration;
    }
};

pub const TcpListenerPoll = struct {
    readable: bool = false,
    socket_error: bool = false,
    socket_hangup: bool = false,
    invalid_socket: bool = false,
};

pub const TcpListenerAccept = struct {
    connection: transport.TcpConnection,
    peer: transport.Ipv4Address,
};

const Entry = struct {
    handle: *resource.ResourceHandle,
    listener: transport.TcpListener,
};

pub const TcpListenerRegistry = struct {
    allocator: std.mem.Allocator,
    resources: *resource.ResourceRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, resources: *resource.ResourceRegistry, capacity: usize) TcpListenerRegistryError!TcpListenerRegistry {
        if (capacity == 0 or capacity > resources.slots.len) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .resources = resources, .capacity = capacity };
    }

    pub fn deinit(self: *TcpListenerRegistry) void {
        for (self.entries.items) |*entry| {
            entry.listener.shutdown();
            self.resources.release_kind(entry.handle, .listener) catch {};
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *TcpListenerRegistry, config: TcpListenerConfig) TcpListenerRegistryError!*resource.ResourceHandle {
        try config.validate();
        if (self.entries.items.len >= self.capacity) return error.ListenerCapacityExceeded;
        const handle = try self.resources.acquire_kind(.listener);
        errdefer self.resources.release_kind(handle, .listener) catch {};
        var listener = try transport.TcpListener.init(config.endpoint, config.backlog);
        errdefer listener.shutdown();
        try self.entries.append(self.allocator, .{ .handle = handle, .listener = listener });
        return handle;
    }

    pub fn poll(self: *TcpListenerRegistry, handle: *resource.ResourceHandle) TcpListenerRegistryError!TcpListenerPoll {
        const entry = try self.lookup(handle);
        const socket = entry.listener.socket orelse return error.NotListening;
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

    pub fn accept(self: *TcpListenerRegistry, handle: *resource.ResourceHandle) TcpListenerRegistryError!?TcpListenerAccept {
        const entry = try self.lookup(handle);
        var pending = entry.listener.accept() catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        const admitted = entry.listener.admit(&pending, .allow) orelse unreachable;
        return .{ .connection = admitted.connection, .peer = admitted.peer };
    }

    pub fn localAddress(self: *TcpListenerRegistry, handle: *resource.ResourceHandle) TcpListenerRegistryError!transport.Ipv4Address {
        return (try self.lookup(handle)).listener.local_address();
    }

    pub fn close(self: *TcpListenerRegistry, handle: *resource.ResourceHandle) TcpListenerRegistryError!void {
        try self.resources.validate_kind(handle, .listener);
        for (self.entries.items, 0..) |_, index| {
            if (self.entries.items[index].handle != handle) continue;
            var entry = self.entries.orderedRemove(index);
            entry.listener.shutdown();
            try self.resources.release_kind(handle, .listener);
            return;
        }
        return error.UnknownListener;
    }

    fn lookup(self: *TcpListenerRegistry, handle: *resource.ResourceHandle) TcpListenerRegistryError!*Entry {
        try self.resources.validate_kind(handle, .listener);
        for (self.entries.items) |*entry| if (entry.handle == handle) return entry;
        return error.UnknownListener;
    }
};

test "TCP listener registries accept nonblocking clients and release handles" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 1);
        defer resources.deinit();
        var listeners = try TcpListenerRegistry.init(allocator, &resources, 1);
        defer listeners.deinit();
        const listener = try listeners.open(.{ .endpoint = transport.Ipv4Address.wildcard(0), .backlog = 1 });
        const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try listeners.localAddress(listener)).port);
        try std.testing.expect(!(try listeners.poll(listener)).readable);
        var client = try transport.TcpConnection.init();
        defer if (client.state != .closed) client.close();
        _ = try client.start_connect(endpoint, 1_000);
        var accepted: ?TcpListenerAccept = null;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if ((try listeners.poll(listener)).readable) accepted = try listeners.accept(listener);
            if (accepted != null) break;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        var connection = accepted orelse return error.TestExpectedEqual;
        defer connection.connection.close();
        try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, connection.peer.octets);
        try listeners.close(listener);
        try std.testing.expectError(error.StaleHandle, listeners.poll(listener));
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "TCP listener registries validate backlog and capacity" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var listeners = try TcpListenerRegistry.init(std.testing.allocator, &resources, 1);
    defer listeners.deinit();
    try std.testing.expectError(error.InvalidConfiguration, listeners.open(.{ .endpoint = transport.Ipv4Address.wildcard(0), .backlog = 0 }));
    _ = try listeners.open(.{ .endpoint = transport.Ipv4Address.wildcard(0), .backlog = 1 });
    try std.testing.expectError(error.ListenerCapacityExceeded, listeners.open(.{ .endpoint = transport.Ipv4Address.wildcard(0), .backlog = 1 }));
}
