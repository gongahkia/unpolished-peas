const std = @import("std");
const host = @import("authoritative_host.zig");

pub const InterestEntityId = u64;
pub const InterestSubscriptionId = u64;
pub const InterestError = error{ InvalidQuery, CapacityExceeded, UnknownSubscription, OutputTooSmall };
pub const Visibility = enum { entered, left };

pub const InterestSubscription = struct {
    id: InterestSubscriptionId,
    observer: host.HostPeerId,
};

pub const InterestQuery = struct {
    subscription: InterestSubscription,
    maximum_results: usize,
};

pub const InterestUpdate = struct {
    entity: InterestEntityId,
    revision: u64,
};

pub const VisibilityChange = struct {
    subscription: InterestSubscription,
    entity: InterestEntityId,
    visibility: Visibility,
};

pub const InterestManagement = struct {
    context: *anyopaque,
    subscribe_fn: *const fn (*anyopaque, host.HostPeerId) InterestError!InterestSubscription,
    unsubscribe_fn: *const fn (*anyopaque, InterestSubscription) InterestError!void,
    query_fn: *const fn (*anyopaque, InterestQuery, []InterestEntityId) InterestError!usize,
    update_fn: *const fn (*anyopaque, InterestUpdate, []VisibilityChange) InterestError!usize,

    pub fn subscribe(self: InterestManagement, observer: host.HostPeerId) InterestError!InterestSubscription {
        if (observer == 0) return error.InvalidQuery;
        const subscription = try self.subscribe_fn(self.context, observer);
        if (subscription.id == 0 or subscription.observer != observer) return error.InvalidQuery;
        return subscription;
    }

    pub fn unsubscribe(self: InterestManagement, subscription: InterestSubscription) InterestError!void {
        if (subscription.id == 0 or subscription.observer == 0) return error.InvalidQuery;
        return self.unsubscribe_fn(self.context, subscription);
    }

    pub fn query(self: InterestManagement, request: InterestQuery, output: []InterestEntityId) InterestError!usize {
        if (request.subscription.id == 0 or request.subscription.observer == 0 or request.maximum_results > output.len) return error.InvalidQuery;
        const count = try self.query_fn(self.context, request, output);
        if (count > request.maximum_results) return error.OutputTooSmall;
        return count;
    }

    pub fn update(self: InterestManagement, update_value: InterestUpdate, output: []VisibilityChange) InterestError!usize {
        if (update_value.entity == 0) return error.InvalidQuery;
        const count = try self.update_fn(self.context, update_value, output);
        if (count > output.len) return error.OutputTooSmall;
        return count;
    }
};

test "interest management contracts route subscriptions queries updates and visibility" {
    const Fixture = struct {
        subscription: ?InterestSubscription = null,

        fn management(self: *@This()) InterestManagement {
            return .{ .context = self, .subscribe_fn = subscribe, .unsubscribe_fn = unsubscribe, .query_fn = query, .update_fn = update };
        }

        fn subscribe(context: *anyopaque, observer: host.HostPeerId) InterestError!InterestSubscription {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.subscription != null) return error.CapacityExceeded;
            const subscription = InterestSubscription{ .id = 1, .observer = observer };
            self.subscription = subscription;
            return subscription;
        }

        fn unsubscribe(context: *anyopaque, subscription: InterestSubscription) InterestError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.subscription == null or self.subscription.?.id != subscription.id) return error.UnknownSubscription;
            self.subscription = null;
        }

        fn query(context: *anyopaque, request: InterestQuery, output: []InterestEntityId) InterestError!usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.subscription == null or self.subscription.?.id != request.subscription.id) return error.UnknownSubscription;
            if (output.len == 0) return error.OutputTooSmall;
            output[0] = 9;
            return 1;
        }

        fn update(context: *anyopaque, update_value: InterestUpdate, output: []VisibilityChange) InterestError!usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            const subscription = self.subscription orelse return error.UnknownSubscription;
            if (output.len == 0) return error.OutputTooSmall;
            output[0] = .{ .subscription = subscription, .entity = update_value.entity, .visibility = .entered };
            return 1;
        }
    };
    var fixture = Fixture{};
    const management = fixture.management();
    const subscription = try management.subscribe(7);
    var entities: [1]InterestEntityId = undefined;
    try std.testing.expectEqual(@as(usize, 1), try management.query(.{ .subscription = subscription, .maximum_results = 1 }, entities[0..]));
    try std.testing.expectEqual(@as(InterestEntityId, 9), entities[0]);
    var changes: [1]VisibilityChange = undefined;
    try std.testing.expectEqual(@as(usize, 1), try management.update(.{ .entity = 9, .revision = 1 }, changes[0..]));
    try std.testing.expectEqual(Visibility.entered, changes[0].visibility);
    try management.unsubscribe(subscription);
    try std.testing.expectError(error.UnknownSubscription, management.update(.{ .entity = 9, .revision = 2 }, changes[0..]));
}

test "interest management validates generic query boundaries" {
    const Rejecting = struct {
        fn subscribe(_: *anyopaque, _: host.HostPeerId) InterestError!InterestSubscription {
            return error.CapacityExceeded;
        }
        fn unsubscribe(_: *anyopaque, _: InterestSubscription) InterestError!void {
            return error.UnknownSubscription;
        }
        fn query(_: *anyopaque, _: InterestQuery, _: []InterestEntityId) InterestError!usize {
            return error.UnknownSubscription;
        }
        fn update(_: *anyopaque, _: InterestUpdate, _: []VisibilityChange) InterestError!usize {
            return error.UnknownSubscription;
        }
    };
    var context = Rejecting{};
    const management = InterestManagement{ .context = &context, .subscribe_fn = Rejecting.subscribe, .unsubscribe_fn = Rejecting.unsubscribe, .query_fn = Rejecting.query, .update_fn = Rejecting.update };
    var entities: [1]InterestEntityId = undefined;
    try @import("std").testing.expectError(error.InvalidQuery, management.subscribe(0));
    try @import("std").testing.expectError(error.InvalidQuery, management.unsubscribe(.{ .id = 0, .observer = 1 }));
    try @import("std").testing.expectError(error.InvalidQuery, management.query(.{ .subscription = .{ .id = 0, .observer = 1 }, .maximum_results = 0 }, entities[0..]));
    try @import("std").testing.expectError(error.InvalidQuery, management.query(.{ .subscription = .{ .id = 1, .observer = 1 }, .maximum_results = 2 }, entities[0..]));
    try @import("std").testing.expectError(error.InvalidQuery, management.update(.{ .entity = 0, .revision = 0 }, &.{}));
}

test "interest management rejects malformed provider results" {
    const InvalidProvider = struct {
        fn subscribe(_: *anyopaque, observer: host.HostPeerId) InterestError!InterestSubscription {
            return .{ .id = 0, .observer = observer };
        }
        fn unsubscribe(_: *anyopaque, _: InterestSubscription) InterestError!void {}
        fn query(_: *anyopaque, _: InterestQuery, _: []InterestEntityId) InterestError!usize {
            return 2;
        }
        fn update(_: *anyopaque, _: InterestUpdate, _: []VisibilityChange) InterestError!usize {
            return 2;
        }
    };
    var context = InvalidProvider{};
    const management = InterestManagement{ .context = &context, .subscribe_fn = InvalidProvider.subscribe, .unsubscribe_fn = InvalidProvider.unsubscribe, .query_fn = InvalidProvider.query, .update_fn = InvalidProvider.update };
    var entities: [1]InterestEntityId = undefined;
    var changes: [1]VisibilityChange = undefined;
    try std.testing.expectError(error.InvalidQuery, management.subscribe(1));
    try std.testing.expectError(error.OutputTooSmall, management.query(.{ .subscription = .{ .id = 1, .observer = 1 }, .maximum_results = 1 }, entities[0..]));
    try std.testing.expectError(error.OutputTooSmall, management.update(.{ .entity = 1, .revision = 1 }, changes[0..]));
}
