const std = @import("std");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");

pub const ShardId = u64;
pub const ShardHealth = enum { healthy, degraded, unavailable };
pub const ShardRouteKind = enum { authoritative, direct, relay };

pub const ShardEndpoint = transport.Endpoint;

pub const ShardRoute = struct {
    id: protocol.RouteId,
    kind: ShardRouteKind,
    endpoint: ShardEndpoint,
};

pub const ShardCapacity = struct {
    maximum_participants: usize,
    active_participants: usize,

    pub fn available(self: ShardCapacity) usize {
        return self.maximum_participants -| self.active_participants;
    }
};

pub const ShardRegistration = struct {
    id: ShardId,
    capacity: ShardCapacity,
    health: ShardHealth,
    route: ShardRoute,
};

pub const ShardDirectoryError = std.mem.Allocator.Error || error{ InvalidConfiguration, DuplicateShard, CapacityExceeded, UnknownShard, OutputTooSmall };

pub const ShardDirectoryConfig = struct {
    maximum_shards: usize,
};

pub const ShardDirectory = struct {
    allocator: std.mem.Allocator,
    config: ShardDirectoryConfig,
    registrations: std.ArrayListUnmanaged(ShardRegistration) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: ShardDirectoryConfig) ShardDirectoryError!ShardDirectory {
        if (config.maximum_shards == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *ShardDirectory) void {
        self.registrations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: ShardDirectory) usize {
        return self.registrations.items.len;
    }

    pub fn register(self: *ShardDirectory, registration: ShardRegistration) ShardDirectoryError!void {
        try validate_registration(registration);
        if (self.index_of(registration.id) != null) return error.DuplicateShard;
        if (self.registrations.items.len == self.config.maximum_shards) return error.CapacityExceeded;
        try self.registrations.ensureUnusedCapacity(self.allocator, 1);
        const insertion = self.insertion_index(registration.id);
        self.registrations.appendAssumeCapacity(registration);
        var index = self.registrations.items.len - 1;
        while (index > insertion) : (index -= 1) self.registrations.items[index] = self.registrations.items[index - 1];
        self.registrations.items[insertion] = registration;
    }

    pub fn unregister(self: *ShardDirectory, id: ShardId) ShardDirectoryError!void {
        const index = self.index_of(id) orelse return error.UnknownShard;
        _ = self.registrations.orderedRemove(index);
    }

    pub fn lookup(self: ShardDirectory, id: ShardId) ?ShardRegistration {
        const index = self.index_of(id) orelse return null;
        return self.registrations.items[index];
    }

    pub fn available_capacity(self: ShardDirectory, id: ShardId) ShardDirectoryError!usize {
        const registration = self.lookup(id) orelse return error.UnknownShard;
        return registration.capacity.available();
    }

    pub fn set_active_participants(self: *ShardDirectory, id: ShardId, active_participants: usize) ShardDirectoryError!void {
        const index = self.index_of(id) orelse return error.UnknownShard;
        if (active_participants > self.registrations.items[index].capacity.maximum_participants) return error.CapacityExceeded;
        self.registrations.items[index].capacity.active_participants = active_participants;
    }

    pub fn set_capacity(self: *ShardDirectory, id: ShardId, capacity: ShardCapacity) ShardDirectoryError!void {
        if (capacity.maximum_participants == 0 or capacity.active_participants > capacity.maximum_participants) return error.InvalidConfiguration;
        const index = self.index_of(id) orelse return error.UnknownShard;
        self.registrations.items[index].capacity = capacity;
    }

    pub fn set_health(self: *ShardDirectory, id: ShardId, health: ShardHealth) ShardDirectoryError!void {
        const index = self.index_of(id) orelse return error.UnknownShard;
        self.registrations.items[index].health = health;
    }

    pub fn set_route(self: *ShardDirectory, id: ShardId, route: ShardRoute) ShardDirectoryError!void {
        if (route.id == 0) return error.InvalidConfiguration;
        const index = self.index_of(id) orelse return error.UnknownShard;
        self.registrations.items[index].route = route;
    }

    pub fn list(self: ShardDirectory, output: []ShardRegistration) ShardDirectoryError!usize {
        if (self.registrations.items.len > output.len) return error.OutputTooSmall;
        @memcpy(output[0..self.registrations.items.len], self.registrations.items);
        return self.registrations.items.len;
    }

    pub fn find_available(self: ShardDirectory, required_participants: usize, route_kind: ?ShardRouteKind) ?ShardRegistration {
        for (self.registrations.items) |registration| {
            if (registration.health != .healthy) continue;
            if (registration.capacity.available() < required_participants) continue;
            if (route_kind) |required_kind| if (registration.route.kind != required_kind) continue;
            return registration;
        }
        return null;
    }

    fn index_of(self: ShardDirectory, id: ShardId) ?usize {
        if (id == 0) return null;
        for (self.registrations.items, 0..) |registration, index| {
            if (registration.id == id) return index;
            if (registration.id > id) return null;
        }
        return null;
    }

    fn insertion_index(self: ShardDirectory, id: ShardId) usize {
        for (self.registrations.items, 0..) |registration, index| if (registration.id > id) return index;
        return self.registrations.items.len;
    }
};

fn validate_registration(registration: ShardRegistration) ShardDirectoryError!void {
    if (registration.id == 0 or registration.route.id == 0 or registration.capacity.maximum_participants == 0 or registration.capacity.active_participants > registration.capacity.maximum_participants) return error.InvalidConfiguration;
}

test "shard directory registers deterministic route capacity and health metadata" {
    var directory = try ShardDirectory.init(std.testing.allocator, .{ .maximum_shards = 2 });
    defer directory.deinit();
    try directory.register(.{
        .id = 2,
        .capacity = .{ .maximum_participants = 5, .active_participants = 2 },
        .health = .healthy,
        .route = .{ .id = 2, .kind = .authoritative, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 9000 }) },
    });
    try directory.register(.{
        .id = 1,
        .capacity = .{ .maximum_participants = 4, .active_participants = 1 },
        .health = .healthy,
        .route = .{ .id = 1, .kind = .relay, .endpoint = transport.Endpoint.from_ipv6(.{ .octets = .{0} ** 15 ++ .{1}, .port = 9001, .scope_id = 0 }) },
    });
    try std.testing.expectEqual(@as(usize, 2), directory.count());
    try std.testing.expectEqual(@as(usize, 3), try directory.available_capacity(2));
    var listed: [2]ShardRegistration = undefined;
    try std.testing.expectEqual(@as(usize, 2), try directory.list(listed[0..]));
    try std.testing.expectEqualSlices(ShardId, &.{ 1, 2 }, &.{ listed[0].id, listed[1].id });
    try std.testing.expectEqual(@as(?ShardRegistration, directory.lookup(1)), directory.find_available(3, .relay));
    try directory.set_active_participants(1, 2);
    try std.testing.expect(directory.find_available(3, .relay) == null);
    try directory.set_capacity(1, .{ .maximum_participants = 5, .active_participants = 2 });
    try std.testing.expectEqual(@as(usize, 3), try directory.available_capacity(1));
    try std.testing.expectEqual(@as(?ShardRegistration, directory.lookup(1)), directory.find_available(3, .relay));
    try directory.set_health(1, .unavailable);
    try directory.set_health(2, .degraded);
    try std.testing.expect(directory.find_available(1, null) == null);
    const direct = ShardRoute{ .id = 3, .kind = .direct, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 10, 0, 0, 2 }, .port = 9002 }) };
    try directory.set_route(2, direct);
    try std.testing.expectEqual(direct, directory.lookup(2).?.route);
    try directory.unregister(1);
    try std.testing.expect(directory.lookup(1) == null);
}

test "shard directory rejects invalid bounded and unknown operations" {
    const registration = ShardRegistration{
        .id = 1,
        .capacity = .{ .maximum_participants = 1, .active_participants = 0 },
        .health = .healthy,
        .route = .{ .id = 1, .kind = .direct, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 1 }) },
    };
    try std.testing.expectError(error.InvalidConfiguration, ShardDirectory.init(std.testing.allocator, .{ .maximum_shards = 0 }));
    var directory = try ShardDirectory.init(std.testing.allocator, .{ .maximum_shards = 1 });
    defer directory.deinit();
    var invalid = registration;
    invalid.id = 0;
    try std.testing.expectError(error.InvalidConfiguration, directory.register(invalid));
    invalid = registration;
    invalid.capacity.active_participants = 2;
    try std.testing.expectError(error.InvalidConfiguration, directory.register(invalid));
    invalid = registration;
    invalid.route.id = 0;
    try std.testing.expectError(error.InvalidConfiguration, directory.register(invalid));
    try directory.register(registration);
    try std.testing.expectError(error.DuplicateShard, directory.register(registration));
    const second = ShardRegistration{ .id = 2, .capacity = registration.capacity, .health = registration.health, .route = .{ .id = 2, .kind = .direct, .endpoint = registration.route.endpoint } };
    try std.testing.expectError(error.CapacityExceeded, directory.register(second));
    try std.testing.expectError(error.CapacityExceeded, directory.set_active_participants(1, 2));
    try std.testing.expectEqual(@as(usize, 1), try directory.available_capacity(1));
    try std.testing.expectError(error.InvalidConfiguration, directory.set_capacity(1, .{ .maximum_participants = 0, .active_participants = 0 }));
    try std.testing.expectEqual(@as(usize, 1), try directory.available_capacity(1));
    try std.testing.expectError(error.UnknownShard, directory.set_health(2, .healthy));
    try std.testing.expectError(error.InvalidConfiguration, directory.set_route(1, .{ .id = 0, .kind = .direct, .endpoint = registration.route.endpoint }));
    var empty: [0]ShardRegistration = .{};
    try std.testing.expectError(error.OutputTooSmall, directory.list(empty[0..]));
    try std.testing.expectError(error.UnknownShard, directory.unregister(2));
}
