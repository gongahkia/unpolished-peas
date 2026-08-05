const std = @import("std");
const protocol = @import("minna-san-protocol");

pub const PeerGroupId = u64;
pub const PeerGroupPeerId = u64;
pub const PeerGroupState = enum { active, closed };

pub const PeerGroupPath = union(enum) {
    direct: protocol.RouteId,
    relay: struct {
        ingress: protocol.RouteId,
        egress: protocol.RouteId,
    },
};

pub const PeerGroupRoute = struct {
    peer: PeerGroupPeerId,
    path: PeerGroupPath,
};

pub const RoutedPeerGroupError = std.mem.Allocator.Error || error{ InvalidConfiguration, DuplicateGroup, GroupCapacityExceeded, UnknownGroup, GroupClosed, RouteCapacityExceeded, DuplicateRoute, UnknownRoute, OutputTooSmall };

pub const RoutedPeerGroupConfig = struct {
    maximum_groups: usize,
    maximum_routes_per_group: usize,
};

pub const RoutedPeerGroupInfo = struct {
    id: PeerGroupId,
    state: PeerGroupState,
    route_count: usize,
};

const Group = struct {
    id: PeerGroupId,
    state: PeerGroupState = .active,
    routes: std.ArrayListUnmanaged(PeerGroupRoute) = .empty,

    fn deinit(self: *Group, allocator: std.mem.Allocator) void {
        self.routes.deinit(allocator);
        self.* = undefined;
    }

    fn info(self: Group) RoutedPeerGroupInfo {
        return .{ .id = self.id, .state = self.state, .route_count = self.routes.items.len };
    }
};

pub const RoutedPeerGroups = struct {
    allocator: std.mem.Allocator,
    config: RoutedPeerGroupConfig,
    groups: std.ArrayListUnmanaged(Group) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: RoutedPeerGroupConfig) RoutedPeerGroupError!RoutedPeerGroups {
        if (config.maximum_groups == 0 or config.maximum_routes_per_group == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *RoutedPeerGroups) void {
        for (self.groups.items) |*group| group.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *RoutedPeerGroups, id: PeerGroupId) RoutedPeerGroupError!void {
        if (id == 0) return error.InvalidConfiguration;
        if (self.index_of(id) != null) return error.DuplicateGroup;
        if (self.groups.items.len == self.config.maximum_groups) return error.GroupCapacityExceeded;
        try self.groups.ensureUnusedCapacity(self.allocator, 1);
        const insertion = self.insertion_index(id);
        self.groups.appendAssumeCapacity(.{ .id = id });
        var index = self.groups.items.len - 1;
        while (index > insertion) : (index -= 1) self.groups.items[index] = self.groups.items[index - 1];
        self.groups.items[insertion] = .{ .id = id };
    }

    pub fn close(self: *RoutedPeerGroups, id: PeerGroupId) RoutedPeerGroupError!void {
        const group = self.group_ptr(id) orelse return error.UnknownGroup;
        group.state = .closed;
    }

    pub fn destroy(self: *RoutedPeerGroups, id: PeerGroupId) RoutedPeerGroupError!void {
        const index = self.index_of(id) orelse return error.UnknownGroup;
        if (self.groups.items[index].state != .closed) return error.GroupClosed;
        self.groups.items[index].deinit(self.allocator);
        _ = self.groups.orderedRemove(index);
    }

    pub fn info(self: RoutedPeerGroups, id: PeerGroupId) ?RoutedPeerGroupInfo {
        const index = self.index_of(id) orelse return null;
        return self.groups.items[index].info();
    }

    pub fn add_route(self: *RoutedPeerGroups, id: PeerGroupId, value: PeerGroupRoute) RoutedPeerGroupError!void {
        if (value.peer == 0 or !valid_path(value.path)) return error.InvalidConfiguration;
        const group = self.group_ptr(id) orelse return error.UnknownGroup;
        if (group.state != .active) return error.GroupClosed;
        if (route_index(group.*, value.peer) != null) return error.DuplicateRoute;
        if (group.routes.items.len == self.config.maximum_routes_per_group) return error.RouteCapacityExceeded;
        try group.routes.ensureUnusedCapacity(self.allocator, 1);
        const insertion = route_insertion_index(group.*, value.peer);
        group.routes.appendAssumeCapacity(value);
        var index = group.routes.items.len - 1;
        while (index > insertion) : (index -= 1) group.routes.items[index] = group.routes.items[index - 1];
        group.routes.items[insertion] = value;
    }

    pub fn remove_route(self: *RoutedPeerGroups, id: PeerGroupId, peer: PeerGroupPeerId) RoutedPeerGroupError!void {
        const group = self.group_ptr(id) orelse return error.UnknownGroup;
        const index = route_index(group.*, peer) orelse return error.UnknownRoute;
        _ = group.routes.orderedRemove(index);
    }

    pub fn route(self: RoutedPeerGroups, id: PeerGroupId, peer: PeerGroupPeerId) ?PeerGroupRoute {
        const index = self.index_of(id) orelse return null;
        const route_index_value = route_index(self.groups.items[index], peer) orelse return null;
        return self.groups.items[index].routes.items[route_index_value];
    }

    pub fn list_routes(self: RoutedPeerGroups, id: PeerGroupId, output: []PeerGroupRoute) RoutedPeerGroupError!usize {
        const index = self.index_of(id) orelse return error.UnknownGroup;
        const routes = self.groups.items[index].routes.items;
        if (routes.len > output.len) return error.OutputTooSmall;
        @memcpy(output[0..routes.len], routes);
        return routes.len;
    }

    fn group_ptr(self: *RoutedPeerGroups, id: PeerGroupId) ?*Group {
        const index = self.index_of(id) orelse return null;
        return &self.groups.items[index];
    }

    fn index_of(self: RoutedPeerGroups, id: PeerGroupId) ?usize {
        if (id == 0) return null;
        for (self.groups.items, 0..) |group, index| {
            if (group.id == id) return index;
            if (group.id > id) return null;
        }
        return null;
    }

    fn insertion_index(self: RoutedPeerGroups, id: PeerGroupId) usize {
        for (self.groups.items, 0..) |group, index| if (group.id > id) return index;
        return self.groups.items.len;
    }
};

fn valid_path(path: PeerGroupPath) bool {
    return switch (path) {
        .direct => |route| route != 0,
        .relay => |relay| relay.ingress != 0 and relay.egress != 0,
    };
}

fn route_index(group: Group, peer: PeerGroupPeerId) ?usize {
    if (peer == 0) return null;
    for (group.routes.items, 0..) |route, index| {
        if (route.peer == peer) return index;
        if (route.peer > peer) return null;
    }
    return null;
}

fn route_insertion_index(group: Group, peer: PeerGroupPeerId) usize {
    for (group.routes.items, 0..) |route, index| if (route.peer > peer) return index;
    return group.routes.items.len;
}

test "routed peer groups retain bounded deterministic direct and relay paths" {
    var groups = try RoutedPeerGroups.init(std.testing.allocator, .{ .maximum_groups = 2, .maximum_routes_per_group = 2 });
    defer groups.deinit();
    try groups.create(2);
    try groups.create(1);
    try groups.add_route(1, .{ .peer = 9, .path = .{ .relay = .{ .ingress = 2, .egress = 3 } } });
    try groups.add_route(1, .{ .peer = 7, .path = .{ .direct = 1 } });
    var routes: [2]PeerGroupRoute = undefined;
    try std.testing.expectEqual(@as(usize, 2), try groups.list_routes(1, routes[0..]));
    try std.testing.expectEqualSlices(PeerGroupPeerId, &.{ 7, 9 }, &.{ routes[0].peer, routes[1].peer });
    try std.testing.expectEqual(PeerGroupPath{ .direct = 1 }, groups.route(1, 7).?.path);
    try groups.remove_route(1, 7);
    try std.testing.expectEqual(@as(usize, 1), groups.info(1).?.route_count);
    try groups.close(1);
    try std.testing.expectEqual(PeerGroupState.closed, groups.info(1).?.state);
    try std.testing.expectError(error.GroupClosed, groups.add_route(1, .{ .peer = 8, .path = .{ .direct = 4 } }));
    try groups.destroy(1);
    try std.testing.expect(groups.info(1) == null);
}

test "routed peer groups reject invalid bounded lifecycle operations" {
    try std.testing.expectError(error.InvalidConfiguration, RoutedPeerGroups.init(std.testing.allocator, .{ .maximum_groups = 0, .maximum_routes_per_group = 1 }));
    var groups = try RoutedPeerGroups.init(std.testing.allocator, .{ .maximum_groups = 1, .maximum_routes_per_group = 1 });
    defer groups.deinit();
    try std.testing.expectError(error.InvalidConfiguration, groups.create(0));
    try groups.create(1);
    try std.testing.expectError(error.DuplicateGroup, groups.create(1));
    try std.testing.expectError(error.GroupCapacityExceeded, groups.create(2));
    try std.testing.expectError(error.InvalidConfiguration, groups.add_route(1, .{ .peer = 0, .path = .{ .direct = 1 } }));
    try std.testing.expectError(error.InvalidConfiguration, groups.add_route(1, .{ .peer = 1, .path = .{ .relay = .{ .ingress = 0, .egress = 1 } } }));
    try groups.add_route(1, .{ .peer = 1, .path = .{ .direct = 1 } });
    try std.testing.expectError(error.DuplicateRoute, groups.add_route(1, .{ .peer = 1, .path = .{ .direct = 2 } }));
    try std.testing.expectError(error.RouteCapacityExceeded, groups.add_route(1, .{ .peer = 2, .path = .{ .direct = 2 } }));
    try std.testing.expectError(error.GroupClosed, groups.destroy(1));
    var output: [0]PeerGroupRoute = .{};
    try std.testing.expectError(error.OutputTooSmall, groups.list_routes(1, output[0..]));
    try std.testing.expectError(error.UnknownRoute, groups.remove_route(1, 2));
    try std.testing.expectError(error.UnknownGroup, groups.close(2));
}
