const std = @import("std");
const core = @import("minna-san-core");
const topology = @import("minna-san-topology");
const config = @import("sdk_config.zig");
const event = @import("event.zig");
const poll_runtime = @import("poll_runtime.zig");
const provider = @import("provider.zig");

pub const RuntimeError = std.mem.Allocator.Error || poll_runtime.PollRuntimeError || provider.ProviderRegistryError || topology.RouteSelectionError || topology.RouteCandidateSelectionError || error{ReentrantPoll};

pub const RuntimePollResult = struct {
    progress: poll_runtime.PollProgress = .idle,
    provider_work_completed: usize = 0,
    next_deadline: ?core.TimeNs = null,
    event: ?event.EventEnvelope = null,

    pub fn deinit(self: *RuntimePollResult) void {
        if (self.event) |*event_envelope| event_envelope.deinit();
        self.* = undefined;
    }
};

pub const Runtime = struct {
    platform_config: core.PlatformConfig,
    poll_runtime: poll_runtime.PollRuntime,
    providers: provider.ProviderRegistry,
    poll_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, sdk: config.Sdk) RuntimeError!Runtime {
        const platform_config = sdk.configuration().platformConfig();
        platform_config.validate() catch return error.InvalidConfiguration;
        return .{
            .platform_config = platform_config,
            .poll_runtime = poll_runtime.PollRuntime.init(allocator, sdk),
            .providers = try provider.ProviderRegistry.init(allocator, platform_config.limits.provider_capacity),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.providers.deinit();
        self.poll_runtime.deinit();
        self.* = undefined;
    }

    pub fn registerProvider(self: *Runtime, item: provider.Provider) provider.ProviderRegistryError!void {
        try self.providers.register(item);
    }

    pub fn start(self: *Runtime) provider.ProviderError!void {
        try self.providers.start();
    }

    pub fn enqueue(self: *Runtime, envelope: event.EventEnvelope) std.mem.Allocator.Error!void {
        try self.poll_runtime.enqueue(envelope);
    }

    pub fn selectRoute(self: *const Runtime, selector: topology.RouteSelector, capabilities: topology.RouteCapabilities) RuntimeError!topology.RouteSelection {
        if (!self.providers.supportsRequirements(selector.config.required_capabilities)) return error.UnsupportedCapabilities;
        return selector.select(capabilities);
    }

    pub fn selectRouteCandidate(self: *const Runtime, selector: topology.RouteCandidateSelector, candidates: []const topology.RouteCandidate, decisions: []topology.RouteCandidateDecision) RuntimeError!topology.RouteCandidateSelection {
        if (!self.providers.supportsRequirements(selector.policy.required_capabilities)) return error.UnsupportedCapabilities;
        return selector.select(candidates, decisions);
    }

    pub fn poll(self: *Runtime, input: poll_runtime.PollInput) RuntimeError!RuntimePollResult {
        try input.validate();
        if (self.poll_active) return error.ReentrantPoll;
        self.poll_active = true;
        defer self.poll_active = false;
        if (input.deadline_ns) |deadline| {
            if (input.now_ns >= deadline) {
                const outcome = try self.poll_runtime.poll(input);
                return .{ .progress = .deadline, .next_deadline = outcome.next_deadline };
            }
        }
        const provider_result = try self.providers.poll(input.now_ns, @min(input.work_budget, self.platform_config.limits.poll_work_budget));
        var outcome = try self.poll_runtime.poll(input);
        errdefer outcome.deinit();
        const next_deadline = if (provider_result.next_deadline) |provider_deadline| blk: {
            if (outcome.next_deadline) |event_deadline| break :blk @min(provider_deadline, event_deadline);
            break :blk provider_deadline;
        } else outcome.next_deadline;
        const progress: poll_runtime.PollProgress = if (outcome.event != null) .event else if (provider_result.work_completed > 0) .provider else .idle;
        const result = RuntimePollResult{
            .progress = progress,
            .provider_work_completed = provider_result.work_completed,
            .next_deadline = next_deadline,
            .event = outcome.event,
        };
        outcome.event = null;
        return result;
    }
};

const FakeProvider = struct {
    polls: u8 = 0,
    capabilities: provider.ProviderCapabilityDescriptor = .{},

    fn asProvider(self: *FakeProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = "runtime-fake" }, self, .{ .init = init, .query_capabilities = queryCapabilities, .poll = poll, .teardown = teardown });
    }

    fn init(context: ?*anyopaque) callconv(.c) c_int {
        _ = context;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *provider.ProviderCapabilityDescriptor) callconv(.c) c_int {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        out_capabilities.* = self.capabilities;
        return @intFromEnum(core.CResult.ok);
    }

    fn poll(context: ?*anyopaque, now: core.TimeNs, work_budget: usize, out_result: *provider.ProviderPollOutput) callconv(.c) c_int {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        _ = now;
        self.polls += 1;
        out_result.* = .{ .work_completed = @min(@as(usize, 1), work_budget) };
        return @intFromEnum(core.CResult.ok);
    }

    fn teardown(context: ?*anyopaque) callconv(.c) void {
        _ = context;
    }
};

test "unified runtime polls providers before yielding queued events" {
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .poll_work_budget = 1 } }).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    var fake = FakeProvider{};
    try runtime.registerProvider(try fake.asProvider());
    try runtime.start();
    try runtime.enqueue(.{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } });
    var result = try runtime.poll(.{ .now_ns = manual.clock().now() });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.provider_work_completed);
    try std.testing.expectEqual(poll_runtime.PollProgress.event, result.progress);
    try std.testing.expect(result.event != null);
    try std.testing.expectEqual(@as(u8, 1), fake.polls);
}

test "unified runtimes reject reentrant caller polls" {
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    runtime.poll_active = true;
    defer runtime.poll_active = false;
    try std.testing.expectError(error.ReentrantPoll, runtime.poll(.{ .now_ns = manual.clock().now() }));
}

test "unified runtimes reject unsupported route features before dialing" {
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    var fake = FakeProvider{ .capabilities = .{ .delivery_bits = core.delivery_capability_bit(.datagrams) } };
    try runtime.registerProvider(try fake.asProvider());
    try runtime.start();
    const selector = try topology.RouteSelector.init(.{ .policy = .direct_first, .allow_relay = false, .allow_authoritative = false, .required_capabilities = .{ .transport_bits = core.transport_capability_bit(.quic) } });
    const candidates = topology.RouteCapabilities{
        .direct = .{ .negotiated = true, .health = .healthy, .capabilities = .{ .transport_bits = core.transport_capability_bit(.quic) } },
        .relay = .{ .negotiated = false, .health = .unavailable },
        .authoritative = .{ .negotiated = false, .health = .unavailable },
    };
    try std.testing.expectError(error.UnsupportedCapabilities, runtime.selectRoute(selector, candidates));
}
