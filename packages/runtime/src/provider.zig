const std = @import("std");
const core = @import("minna-san-core");

pub const max_provider_name_bytes: usize = 64;

pub const ProviderError = error{
    InvalidConfiguration,
    InvalidName,
    InvalidState,
    PollFailed,
};

pub fn disposition_for_error(err: ProviderError) core.ErrorDisposition {
    return core.disposition_for_any_error(err);
}

pub const ProviderCapability = enum {
    datagrams,
    streams,
    tls,
    quic,
    http1,
    http2,
    http3,
    websocket,
    stun,
    turn,
};

pub const ProviderCapabilities = packed struct(u16) {
    datagrams: bool = false,
    streams: bool = false,
    tls: bool = false,
    quic: bool = false,
    http1: bool = false,
    http2: bool = false,
    http3: bool = false,
    websocket: bool = false,
    stun: bool = false,
    turn: bool = false,
    reserved: u6 = 0,

    pub fn supports(self: ProviderCapabilities, capability: ProviderCapability) bool {
        return switch (capability) {
            .datagrams => self.datagrams,
            .streams => self.streams,
            .tls => self.tls,
            .quic => self.quic,
            .http1 => self.http1,
            .http2 => self.http2,
            .http3 => self.http3,
            .websocket => self.websocket,
            .stun => self.stun,
            .turn => self.turn,
        };
    }
};

pub const ProviderConfig = struct {
    name: []const u8,
    capabilities: ProviderCapabilities = .{},
    poll_work_budget: usize = 1,

    pub fn validate(self: ProviderConfig) ProviderError!void {
        if (self.name.len == 0 or self.name.len > max_provider_name_bytes) return error.InvalidName;
        for (self.name) |byte| if (!(byte == '-' or byte == '_' or std.ascii.isAlphanumeric(byte))) return error.InvalidName;
        if (self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};

pub const ProviderPollResult = struct {
    work_completed: usize = 0,
    next_deadline: ?core.TimeNs = null,

    pub fn validate(self: ProviderPollResult, budget: usize) ProviderError!void {
        if (self.work_completed > budget) return error.PollFailed;
    }
};

pub const ProviderVTable = struct {
    start: *const fn (context: *anyopaque) ProviderError!void,
    poll: *const fn (context: *anyopaque, now: core.TimeNs, work_budget: usize) ProviderError!ProviderPollResult,
    stop: *const fn (context: *anyopaque) void,
};

pub const ProviderState = enum {
    registered,
    active,
    failed,
    stopped,
};

pub const Provider = struct {
    config: ProviderConfig,
    context: *anyopaque,
    vtable: ProviderVTable,
    state: ProviderState = .registered,

    pub fn init(config: ProviderConfig, context: *anyopaque, vtable: ProviderVTable) ProviderError!Provider {
        try config.validate();
        return .{ .config = config, .context = context, .vtable = vtable };
    }

    pub fn start(self: *Provider) ProviderError!void {
        if (self.state != .registered) return error.InvalidState;
        self.vtable.start(self.context) catch {
            self.state = .failed;
            return error.PollFailed;
        };
        self.state = .active;
    }

    pub fn poll(self: *Provider, now: core.TimeNs) ProviderError!ProviderPollResult {
        return self.pollWithBudget(now, self.config.poll_work_budget);
    }

    fn pollWithBudget(self: *Provider, now: core.TimeNs, work_budget: usize) ProviderError!ProviderPollResult {
        if (self.state != .active) return error.InvalidState;
        const result = self.vtable.poll(self.context, now, work_budget) catch {
            self.state = .failed;
            return error.PollFailed;
        };
        result.validate(work_budget) catch {
            self.state = .failed;
            return error.PollFailed;
        };
        return result;
    }

    pub fn stop(self: *Provider) void {
        if (self.state == .registered or self.state == .active or self.state == .failed) self.vtable.stop(self.context);
        self.state = .stopped;
    }
};

pub const ProviderRegistryError = std.mem.Allocator.Error || ProviderError || error{ ProviderCapacityExceeded, DuplicateProvider };

pub const ProviderRegistry = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayListUnmanaged(Provider) = .empty,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) ProviderError!ProviderRegistry {
        if (capacity == 0 or capacity > core.max_provider_capacity) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *ProviderRegistry) void {
        for (self.providers.items) |*provider| provider.stop();
        self.providers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *ProviderRegistry, provider: Provider) ProviderRegistryError!void {
        for (self.providers.items) |registered| if (std.mem.eql(u8, registered.config.name, provider.config.name)) return error.DuplicateProvider;
        if (self.providers.items.len >= self.capacity) return error.ProviderCapacityExceeded;
        try self.providers.append(self.allocator, provider);
    }

    pub fn start(self: *ProviderRegistry) ProviderError!void {
        for (self.providers.items) |*provider| try provider.start();
    }

    pub fn poll(self: *ProviderRegistry, now: core.TimeNs, work_budget: usize) ProviderError!ProviderPollResult {
        if (work_budget == 0) return error.InvalidConfiguration;
        var remaining = work_budget;
        var result = ProviderPollResult{};
        for (self.providers.items) |*provider| {
            if (remaining == 0) break;
            const provider_budget = @min(remaining, provider.config.poll_work_budget);
            const provider_result = try provider.pollWithBudget(now, provider_budget);
            result.work_completed += provider_result.work_completed;
            remaining -= provider_result.work_completed;
            if (provider_result.next_deadline) |deadline| {
                if (result.next_deadline == null or deadline < result.next_deadline.?) result.next_deadline = deadline;
            }
        }
        return result;
    }
};

const FakeProvider = struct {
    starts: u8 = 0,
    stops: u8 = 0,
    work_completed: usize = 0,
    fail_start: bool = false,

    fn provider(self: *FakeProvider) ProviderError!Provider {
        return Provider.init(.{ .name = "fake", .capabilities = .{ .datagrams = true }, .poll_work_budget = 2 }, self, .{ .start = start, .poll = poll, .stop = stop });
    }

    fn start(context: *anyopaque) ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(context));
        if (self.fail_start) return error.PollFailed;
        self.starts += 1;
    }

    fn poll(context: *anyopaque, now: core.TimeNs, work_budget: usize) ProviderError!ProviderPollResult {
        const self: *FakeProvider = @ptrCast(@alignCast(context));
        _ = now;
        self.work_completed += work_budget;
        return .{ .work_completed = work_budget };
    }

    fn stop(context: *anyopaque) void {
        const self: *FakeProvider = @ptrCast(@alignCast(context));
        self.stops += 1;
    }
};

test "providers have explicit bounded lifecycle" {
    var fake = FakeProvider{};
    var provider = try fake.provider();
    try provider.start();
    try @import("std").testing.expectEqual(@as(u8, 1), fake.starts);
    try @import("std").testing.expect(provider.config.capabilities.supports(.datagrams));
    try @import("std").testing.expectEqual(@as(usize, 2), (try provider.poll(0)).work_completed);
    provider.stop();
    try @import("std").testing.expectEqual(@as(u8, 1), fake.stops);
    try @import("std").testing.expectError(error.InvalidState, provider.poll(0));
}

test "provider start failures become terminal" {
    var fake = FakeProvider{ .fail_start = true };
    var provider = try fake.provider();
    try @import("std").testing.expectError(error.PollFailed, provider.start());
    try @import("std").testing.expectEqual(ProviderState.failed, provider.state);
}

test "equivalent provider failures map to one public class" {
    var first_fake = FakeProvider{ .fail_start = true };
    var second_fake = FakeProvider{ .fail_start = true };
    var first = try first_fake.provider();
    var second = try second_fake.provider();
    var first_failure: ?ProviderError = null;
    first.start() catch |err| {
        first_failure = err;
    };
    var second_failure: ?ProviderError = null;
    second.start() catch |err| {
        second_failure = err;
    };
    try @import("std").testing.expectEqual(error.PollFailed, first_failure.?);
    try @import("std").testing.expectEqual(error.PollFailed, second_failure.?);
    try @import("std").testing.expectEqual(disposition_for_error(first_failure.?), disposition_for_error(second_failure.?));
    try @import("std").testing.expectEqual(core.ErrorClass.transport_failure, disposition_for_error(first_failure.?).class);
}

test "provider registries enforce capacity and deterministic budgets" {
    var first = FakeProvider{};
    var second = FakeProvider{};
    var registry = try ProviderRegistry.init(std.testing.allocator, 2);
    defer registry.deinit();
    try registry.register(try first.provider());
    try std.testing.expectError(error.DuplicateProvider, registry.register(try second.provider()));
    var second_provider = try second.provider();
    second_provider.config.name = "second";
    try registry.register(second_provider);
    try registry.start();
    try std.testing.expectEqual(@as(usize, 3), (try registry.poll(0, 3)).work_completed);
    try std.testing.expectEqual(@as(usize, 2), first.work_completed);
    try std.testing.expectEqual(@as(usize, 1), second.work_completed);
    var third = FakeProvider{};
    var third_provider = try third.provider();
    third_provider.config.name = "third";
    try std.testing.expectError(error.ProviderCapacityExceeded, registry.register(third_provider));
}
