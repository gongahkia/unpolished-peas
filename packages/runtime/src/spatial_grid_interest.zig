const std = @import("std");
const interest = @import("interest_management.zig");
const host = @import("authoritative_host.zig");

pub const GridPosition = struct {
    x: i64,
    y: i64,
};

pub const GridRegion = struct {
    center: GridPosition,
    radius_cells: u32,
};

pub const GridEntityUpdate = struct {
    entity: interest.InterestEntityId,
    position: GridPosition,
    revision: u64,
};

pub const SpatialGridInterestError = std.mem.Allocator.Error || interest.InterestError || error{ InvalidConfiguration, UnknownEntity, StaleUpdate };

pub const SpatialGridInterestConfig = struct {
    cell_size: i64,
    maximum_entities: usize,
    maximum_subscriptions: usize,
};

const Cell = struct {
    x: i64,
    y: i64,
};

const Entity = struct {
    id: interest.InterestEntityId,
    position: GridPosition,
    revision: u64,
};

const Subscription = struct {
    value: interest.InterestSubscription,
    region: GridRegion,
};

pub const SpatialGridInterest = struct {
    allocator: std.mem.Allocator,
    config: SpatialGridInterestConfig,
    entities: std.ArrayListUnmanaged(Entity) = .empty,
    subscriptions: std.ArrayListUnmanaged(Subscription) = .empty,
    next_subscription_id: interest.InterestSubscriptionId = 1,

    pub fn init(allocator: std.mem.Allocator, config: SpatialGridInterestConfig) SpatialGridInterestError!SpatialGridInterest {
        if (config.cell_size <= 0 or config.maximum_entities == 0 or config.maximum_subscriptions == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *SpatialGridInterest) void {
        self.entities.deinit(self.allocator);
        self.subscriptions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn entity_count(self: SpatialGridInterest) usize {
        return self.entities.items.len;
    }

    pub fn subscription_count(self: SpatialGridInterest) usize {
        return self.subscriptions.items.len;
    }

    pub fn subscribe(self: *SpatialGridInterest, observer: host.HostPeerId, region: GridRegion) SpatialGridInterestError!interest.InterestSubscription {
        if (observer == 0) return error.InvalidQuery;
        if (self.subscriptions.items.len == self.config.maximum_subscriptions) return error.CapacityExceeded;
        const id = self.next_subscription_id;
        const next_id = std.math.add(interest.InterestSubscriptionId, id, 1) catch return error.CapacityExceeded;
        const value = interest.InterestSubscription{ .id = id, .observer = observer };
        try self.subscriptions.append(self.allocator, .{ .value = value, .region = region });
        self.next_subscription_id = next_id;
        return value;
    }

    pub fn unsubscribe(self: *SpatialGridInterest, value: interest.InterestSubscription) SpatialGridInterestError!void {
        const index = self.subscription_index(value) orelse return error.UnknownSubscription;
        _ = self.subscriptions.orderedRemove(index);
    }

    pub fn query(self: SpatialGridInterest, request: interest.InterestQuery, output: []interest.InterestEntityId) SpatialGridInterestError!usize {
        if (request.maximum_results > output.len) return error.InvalidQuery;
        const current = self.subscription_for(request.subscription) orelse return error.UnknownSubscription;
        const count = self.visible_count(current.region);
        if (count > request.maximum_results) return error.OutputTooSmall;
        var output_index: usize = 0;
        for (self.entities.items) |entity| {
            if (!self.visible(current.region, entity.position)) continue;
            output[output_index] = entity.id;
            output_index += 1;
        }
        return output_index;
    }

    pub fn update_subscription(self: *SpatialGridInterest, value: interest.InterestSubscription, region: GridRegion, output: []interest.VisibilityChange) SpatialGridInterestError!usize {
        const index = self.subscription_index(value) orelse return error.UnknownSubscription;
        const current = self.subscriptions.items[index];
        const count = self.region_change_count(current, region);
        if (count > output.len) return error.OutputTooSmall;
        self.write_region_changes(current, region, output);
        self.subscriptions.items[index].region = region;
        return count;
    }

    pub fn update_entity(self: *SpatialGridInterest, update: GridEntityUpdate, output: []interest.VisibilityChange) SpatialGridInterestError!usize {
        if (update.entity == 0) return error.InvalidQuery;
        if (self.entity_index(update.entity)) |index| {
            const current = self.entities.items[index];
            if (update.revision <= current.revision) return error.StaleUpdate;
            const count = self.entity_change_count(current.position, update.position);
            if (count > output.len) return error.OutputTooSmall;
            self.write_entity_changes(update.entity, current.position, update.position, output);
            self.entities.items[index] = .{ .id = update.entity, .position = update.position, .revision = update.revision };
            return count;
        }
        if (self.entities.items.len == self.config.maximum_entities) return error.CapacityExceeded;
        const count = self.entity_change_count(null, update.position);
        if (count > output.len) return error.OutputTooSmall;
        try self.entities.ensureUnusedCapacity(self.allocator, 1);
        self.write_entity_changes(update.entity, null, update.position, output);
        const insertion = self.entity_insertion_index(update.entity);
        self.entities.appendAssumeCapacity(.{ .id = update.entity, .position = update.position, .revision = update.revision });
        var item_index = self.entities.items.len - 1;
        while (item_index > insertion) : (item_index -= 1) self.entities.items[item_index] = self.entities.items[item_index - 1];
        self.entities.items[insertion] = .{ .id = update.entity, .position = update.position, .revision = update.revision };
        return count;
    }

    pub fn remove_entity(self: *SpatialGridInterest, entity: interest.InterestEntityId, output: []interest.VisibilityChange) SpatialGridInterestError!usize {
        const index = self.entity_index(entity) orelse return error.UnknownEntity;
        const current = self.entities.items[index];
        const count = self.entity_change_count(current.position, null);
        if (count > output.len) return error.OutputTooSmall;
        self.write_entity_changes(entity, current.position, null, output);
        _ = self.entities.orderedRemove(index);
        return count;
    }

    fn subscription_for(self: SpatialGridInterest, value: interest.InterestSubscription) ?Subscription {
        const index = self.subscription_index(value) orelse return null;
        return self.subscriptions.items[index];
    }

    fn subscription_index(self: SpatialGridInterest, value: interest.InterestSubscription) ?usize {
        if (value.id == 0 or value.observer == 0) return null;
        for (self.subscriptions.items, 0..) |candidate, index| {
            if (candidate.value.id == value.id and candidate.value.observer == value.observer) return index;
        }
        return null;
    }

    fn entity_index(self: SpatialGridInterest, id: interest.InterestEntityId) ?usize {
        for (self.entities.items, 0..) |entity, index| {
            if (entity.id == id) return index;
            if (entity.id > id) return null;
        }
        return null;
    }

    fn entity_insertion_index(self: SpatialGridInterest, id: interest.InterestEntityId) usize {
        for (self.entities.items, 0..) |entity, index| if (entity.id > id) return index;
        return self.entities.items.len;
    }

    fn visible_count(self: SpatialGridInterest, region: GridRegion) usize {
        var count: usize = 0;
        for (self.entities.items) |entity| {
            if (self.visible(region, entity.position)) count += 1;
        }
        return count;
    }

    fn region_change_count(self: SpatialGridInterest, current: Subscription, next: GridRegion) usize {
        var count: usize = 0;
        for (self.entities.items) |entity| {
            if (self.visible(current.region, entity.position) != self.visible(next, entity.position)) count += 1;
        }
        return count;
    }

    fn entity_change_count(self: SpatialGridInterest, before: ?GridPosition, after: ?GridPosition) usize {
        var count: usize = 0;
        for (self.subscriptions.items) |current| {
            const was_visible = if (before) |position| self.visible(current.region, position) else false;
            const is_visible = if (after) |position| self.visible(current.region, position) else false;
            if (was_visible != is_visible) count += 1;
        }
        return count;
    }

    fn write_region_changes(self: SpatialGridInterest, current: Subscription, next: GridRegion, output: []interest.VisibilityChange) void {
        var output_index: usize = 0;
        for (self.entities.items) |entity| {
            const was_visible = self.visible(current.region, entity.position);
            const is_visible = self.visible(next, entity.position);
            if (was_visible == is_visible) continue;
            output[output_index] = .{ .subscription = current.value, .entity = entity.id, .visibility = if (is_visible) .entered else .left };
            output_index += 1;
        }
    }

    fn write_entity_changes(self: SpatialGridInterest, entity: interest.InterestEntityId, before: ?GridPosition, after: ?GridPosition, output: []interest.VisibilityChange) void {
        var output_index: usize = 0;
        for (self.subscriptions.items) |current| {
            const was_visible = if (before) |position| self.visible(current.region, position) else false;
            const is_visible = if (after) |position| self.visible(current.region, position) else false;
            if (was_visible == is_visible) continue;
            output[output_index] = .{ .subscription = current.value, .entity = entity, .visibility = if (is_visible) .entered else .left };
            output_index += 1;
        }
    }

    fn visible(self: SpatialGridInterest, region: GridRegion, position: GridPosition) bool {
        const center = self.cell_for(region.center);
        const cell = self.cell_for(position);
        const radius: i64 = @intCast(region.radius_cells);
        return cell.x >= center.x -| radius and cell.x <= center.x +| radius and cell.y >= center.y -| radius and cell.y <= center.y +| radius;
    }

    fn cell_for(self: SpatialGridInterest, position: GridPosition) Cell {
        return .{ .x = @divFloor(position.x, self.config.cell_size), .y = @divFloor(position.y, self.config.cell_size) };
    }
};

test "spatial grid interest produces bounded deterministic queries and changes" {
    var grid = try SpatialGridInterest.init(std.testing.allocator, .{ .cell_size = 10, .maximum_entities = 3, .maximum_subscriptions = 2 });
    defer grid.deinit();
    var changes: [3]interest.VisibilityChange = undefined;
    try std.testing.expectEqual(@as(usize, 0), try grid.update_entity(.{ .entity = 2, .position = .{ .x = 10, .y = 0 }, .revision = 1 }, changes[0..]));
    try std.testing.expectEqual(@as(usize, 0), try grid.update_entity(.{ .entity = 1, .position = .{ .x = 0, .y = 0 }, .revision = 1 }, changes[0..]));
    try std.testing.expectEqual(@as(usize, 0), try grid.update_entity(.{ .entity = 3, .position = .{ .x = 20, .y = 0 }, .revision = 1 }, changes[0..]));
    const subscription = try grid.subscribe(7, .{ .center = .{ .x = 0, .y = 0 }, .radius_cells = 1 });
    var entities: [2]interest.InterestEntityId = undefined;
    try std.testing.expectEqual(@as(usize, 2), try grid.query(.{ .subscription = subscription, .maximum_results = 2 }, entities[0..]));
    try std.testing.expectEqualSlices(interest.InterestEntityId, &.{ 1, 2 }, entities[0..]);
    try std.testing.expectEqual(@as(usize, 1), try grid.update_entity(.{ .entity = 3, .position = .{ .x = 10, .y = 0 }, .revision = 2 }, changes[0..]));
    try std.testing.expectEqual(interest.Visibility.entered, changes[0].visibility);
    try std.testing.expectEqual(@as(interest.InterestEntityId, 3), changes[0].entity);
    try std.testing.expectEqual(@as(usize, 1), try grid.update_entity(.{ .entity = 2, .position = .{ .x = 30, .y = 0 }, .revision = 2 }, changes[0..]));
    try std.testing.expectEqual(interest.Visibility.left, changes[0].visibility);
    try std.testing.expectEqual(@as(usize, 3), try grid.update_subscription(subscription, .{ .center = .{ .x = 30, .y = 0 }, .radius_cells = 0 }, changes[0..]));
    try std.testing.expectEqualSlices(interest.Visibility, &.{ .left, .entered, .left }, &.{ changes[0].visibility, changes[1].visibility, changes[2].visibility });
    try std.testing.expectEqualSlices(interest.InterestEntityId, &.{ 1, 2, 3 }, &.{ changes[0].entity, changes[1].entity, changes[2].entity });
    try std.testing.expectEqual(@as(usize, 1), try grid.remove_entity(2, changes[0..]));
    try std.testing.expectEqual(interest.Visibility.left, changes[0].visibility);
}

test "spatial grid interest preserves state across bounded failure paths" {
    var grid = try SpatialGridInterest.init(std.testing.allocator, .{ .cell_size = 10, .maximum_entities = 1, .maximum_subscriptions = 1 });
    defer grid.deinit();
    const subscription = try grid.subscribe(1, .{ .center = .{ .x = -1, .y = -1 }, .radius_cells = 0 });
    var changes: [1]interest.VisibilityChange = undefined;
    try std.testing.expectError(error.OutputTooSmall, grid.update_entity(.{ .entity = 1, .position = .{ .x = -1, .y = -1 }, .revision = 1 }, &.{}));
    try std.testing.expectEqual(@as(usize, 0), grid.entity_count());
    try std.testing.expectEqual(@as(usize, 1), try grid.update_entity(.{ .entity = 1, .position = .{ .x = -1, .y = -1 }, .revision = 1 }, changes[0..]));
    try std.testing.expectEqual(interest.Visibility.entered, changes[0].visibility);
    try std.testing.expectError(error.OutputTooSmall, grid.update_subscription(subscription, .{ .center = .{ .x = 0, .y = 0 }, .radius_cells = 0 }, &.{}));
    var visible: [1]interest.InterestEntityId = undefined;
    try std.testing.expectEqual(@as(usize, 1), try grid.query(.{ .subscription = subscription, .maximum_results = 1 }, visible[0..]));
    try std.testing.expectEqual(@as(interest.InterestEntityId, 1), visible[0]);
    try std.testing.expectError(error.StaleUpdate, grid.update_entity(.{ .entity = 1, .position = .{ .x = 0, .y = 0 }, .revision = 1 }, changes[0..]));
    try std.testing.expectError(error.CapacityExceeded, grid.update_entity(.{ .entity = 2, .position = .{ .x = 0, .y = 0 }, .revision = 1 }, changes[0..]));
    try std.testing.expectError(error.CapacityExceeded, grid.subscribe(2, .{ .center = .{ .x = 0, .y = 0 }, .radius_cells = 0 }));
    try std.testing.expectError(error.OutputTooSmall, grid.query(.{ .subscription = subscription, .maximum_results = 0 }, &.{}));
    try std.testing.expectError(error.UnknownSubscription, grid.unsubscribe(.{ .id = subscription.id, .observer = 2 }));
    try grid.unsubscribe(subscription);
    var entities: [1]interest.InterestEntityId = undefined;
    try std.testing.expectError(error.UnknownSubscription, grid.query(.{ .subscription = subscription, .maximum_results = 1 }, entities[0..]));
    try std.testing.expectError(error.InvalidConfiguration, SpatialGridInterest.init(std.testing.allocator, .{ .cell_size = 0, .maximum_entities = 1, .maximum_subscriptions = 1 }));
}
