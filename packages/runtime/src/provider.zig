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

    pub fn bits(self: ProviderCapabilities) u16 {
        return @bitCast(self);
    }

    pub fn fromBits(capability_bits: u16) ProviderCapabilities {
        return @bitCast(capability_bits);
    }

    pub fn isValid(self: ProviderCapabilities) bool {
        return self.reserved == 0;
    }

    pub fn contains(self: ProviderCapabilities, required: ProviderCapabilities) bool {
        return (self.bits() & required.bits()) == required.bits();
    }
};

pub const ProviderConfig = struct {
    name: []const u8,
    capabilities: ProviderCapabilities = .{},
    poll_work_budget: usize = 1,

    pub fn validate(self: ProviderConfig) ProviderError!void {
        if (self.name.len == 0 or self.name.len > max_provider_name_bytes) return error.InvalidName;
        for (self.name) |byte| if (!(byte == '-' or byte == '_' or std.ascii.isAlphanumeric(byte))) return error.InvalidName;
        if (!self.capabilities.isValid() or self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};

pub const ProviderPollResult = struct {
    work_completed: usize = 0,
    next_deadline: ?core.TimeNs = null,

    pub fn validate(self: ProviderPollResult, budget: usize) ProviderError!void {
        if (self.work_completed > budget) return error.PollFailed;
    }
};

pub const ProviderPollOutput = extern struct {
    work_completed: usize = 0,
    next_deadline_ns: core.TimeNs = 0,
    has_next_deadline: u8 = 0,
    reserved: [7]u8 = [_]u8{0} ** 7,

    fn toResult(self: ProviderPollOutput) ProviderError!ProviderPollResult {
        if (self.has_next_deadline > 1 or !std.mem.allEqual(u8, self.reserved[0..], 0)) return error.PollFailed;
        return .{ .work_completed = self.work_completed, .next_deadline = if (self.has_next_deadline == 1) self.next_deadline_ns else null };
    }
};

pub const ProviderVTable = extern struct {
    init: *const fn (context: ?*anyopaque) callconv(.c) c_int,
    query_capabilities: *const fn (context: ?*anyopaque, out_capabilities: *u16) callconv(.c) c_int,
    poll: *const fn (context: ?*anyopaque, now: core.TimeNs, work_budget: usize, out_result: *ProviderPollOutput) callconv(.c) c_int,
    teardown: *const fn (context: ?*anyopaque) callconv(.c) void,
};

pub const ProviderState = enum {
    registered,
    active,
    failed,
    stopped,
};

pub const Provider = struct {
    config: ProviderConfig,
    context: ?*anyopaque,
    vtable: ProviderVTable,
    capabilities: ProviderCapabilities = .{},
    state: ProviderState = .registered,
    initialized: bool = false,
    last_failure: ?core.ErrorDisposition = null,

    pub fn init(config: ProviderConfig, context: ?*anyopaque, vtable: ProviderVTable) ProviderError!Provider {
        try config.validate();
        return .{ .config = config, .context = context, .vtable = vtable };
    }

    pub fn start(self: *Provider) ProviderError!void {
        if (self.state != .registered) return error.InvalidState;
        const init_result = self.vtable.init(self.context);
        if (init_result != @intFromEnum(core.CResult.ok)) return self.fail(init_result);
        self.initialized = true;
        var capability_bits: u16 = 0;
        const capability_result = self.vtable.query_capabilities(self.context, &capability_bits);
        if (capability_result != @intFromEnum(core.CResult.ok)) return self.failAndTeardown(capability_result);
        const capabilities = ProviderCapabilities.fromBits(capability_bits);
        if (!capabilities.isValid() or !capabilities.contains(self.config.capabilities)) return self.failAndTeardown(@intFromEnum(core.CResult.unsupported));
        self.capabilities = capabilities;
        self.state = .active;
    }

    pub fn poll(self: *Provider, now: core.TimeNs) ProviderError!ProviderPollResult {
        return self.pollWithBudget(now, self.config.poll_work_budget);
    }

    fn pollWithBudget(self: *Provider, now: core.TimeNs, work_budget: usize) ProviderError!ProviderPollResult {
        if (self.state != .active) return error.InvalidState;
        var output = ProviderPollOutput{};
        const poll_result = self.vtable.poll(self.context, now, work_budget, &output);
        if (poll_result != @intFromEnum(core.CResult.ok)) return self.fail(poll_result);
        const result = output.toResult() catch return self.fail(@intFromEnum(core.CResult.internal));
        result.validate(work_budget) catch return self.fail(@intFromEnum(core.CResult.internal));
        return result;
    }

    pub fn stop(self: *Provider) void {
        if (self.initialized) self.vtable.teardown(self.context);
        self.initialized = false;
        self.state = .stopped;
    }

    fn fail(self: *Provider, result_code: c_int) ProviderError {
        const result = core.c_result_from_code(result_code) orelse .internal;
        self.last_failure = core.disposition_for_c_result(result);
        self.state = .failed;
        return error.PollFailed;
    }

    fn failAndTeardown(self: *Provider, result_code: c_int) ProviderError {
        if (self.initialized) self.vtable.teardown(self.context);
        self.initialized = false;
        return self.fail(result_code);
    }
};

pub const ProviderRegistryError = std.mem.Allocator.Error || ProviderError || error{ ProviderCapacityExceeded, DuplicateProvider, UnknownProvider };

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
        try provider.config.validate();
        if (provider.state != .registered) return error.InvalidState;
        for (self.providers.items) |registered| if (std.mem.eql(u8, registered.config.name, provider.config.name)) return error.DuplicateProvider;
        if (self.providers.items.len >= self.capacity) return error.ProviderCapacityExceeded;
        try self.providers.append(self.allocator, provider);
    }

    pub fn start(self: *ProviderRegistry) ProviderError!void {
        var started: usize = 0;
        for (self.providers.items) |*provider| {
            provider.start() catch |err| {
                for (self.providers.items[0..started]) |*started_provider| started_provider.stop();
                return err;
            };
            started += 1;
        }
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

    pub fn remove(self: *ProviderRegistry, name: []const u8) ProviderRegistryError!void {
        for (self.providers.items, 0..) |registered, index| {
            if (!std.mem.eql(u8, registered.config.name, name)) continue;
            self.providers.items[index].stop();
            for (self.providers.items[index + 1 ..], index..) |item, destination| self.providers.items[destination] = item;
            self.providers.items.len -= 1;
            return;
        }
        return error.UnknownProvider;
    }
};

const FakeProvider = struct {
    starts: u8 = 0,
    stops: u8 = 0,
    work_completed: usize = 0,
    fail_start: bool = false,
    fail_poll: bool = false,

    fn provider(self: *FakeProvider) ProviderError!Provider {
        return Provider.init(.{ .name = "fake", .capabilities = .{ .datagrams = true }, .poll_work_budget = 2 }, self, .{ .init = init, .query_capabilities = queryCapabilities, .poll = poll, .teardown = teardown });
    }

    fn init(context: ?*anyopaque) callconv(.c) c_int {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        if (self.fail_start) return @intFromEnum(core.CResult.transport_failure);
        self.starts += 1;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *u16) callconv(.c) c_int {
        _ = context;
        out_capabilities.* = (ProviderCapabilities{ .datagrams = true }).bits();
        return @intFromEnum(core.CResult.ok);
    }

    fn poll(context: ?*anyopaque, now: core.TimeNs, work_budget: usize, out_result: *ProviderPollOutput) callconv(.c) c_int {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        _ = now;
        if (self.fail_poll) return @intFromEnum(core.CResult.transport_failure);
        self.work_completed += work_budget;
        out_result.* = .{ .work_completed = work_budget };
        return @intFromEnum(core.CResult.ok);
    }

    fn teardown(context: ?*anyopaque) callconv(.c) void {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        self.stops += 1;
    }
};

test "providers have explicit bounded lifecycle" {
    var fake = FakeProvider{};
    var provider = try fake.provider();
    try provider.start();
    try @import("std").testing.expectEqual(@as(u8, 1), fake.starts);
    try @import("std").testing.expect(provider.capabilities.supports(.datagrams));
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
    var invalid = try third.provider();
    invalid.config.poll_work_budget = 0;
    try std.testing.expectError(error.InvalidConfiguration, registry.register(invalid));
}

test "provider registries remove failed providers after teardown" {
    var first = FakeProvider{};
    var second = FakeProvider{ .fail_poll = true };
    var registry = try ProviderRegistry.init(std.testing.allocator, 2);
    defer registry.deinit();
    try registry.register(try first.provider());
    var second_provider = try second.provider();
    second_provider.config.name = "second";
    try registry.register(second_provider);
    try registry.start();
    try std.testing.expectError(error.PollFailed, registry.poll(0, 3));
    try std.testing.expectEqual(ProviderState.failed, registry.providers.items[1].state);
    try registry.remove("second");
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqual(@as(u8, 1), second.stops);
    try std.testing.expectError(error.UnknownProvider, registry.remove("second"));
}
