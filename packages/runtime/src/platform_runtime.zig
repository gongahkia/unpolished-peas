const std = @import("std");
const core = @import("minna-san-core");
const topology = @import("minna-san-topology");
const config = @import("sdk_config.zig");
const event = @import("event.zig");
const poll_runtime = @import("poll_runtime.zig");
const provider = @import("provider.zig");
const channel_delivery = @import("channel_delivery.zig");
const service_module = @import("service_module.zig");
const security_policy = @import("security_policy.zig");

pub const RuntimeError = std.mem.Allocator.Error || poll_runtime.PollRuntimeError || provider.ProviderRegistryError || topology.RouteSelectionError || topology.RouteCandidateSelectionError || channel_delivery.ChannelDeliveryError || service_module.ServiceModuleError || security_policy.SecurityPolicyError || error{ReentrantPoll};

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
    security_policy: security_policy.RuntimeSecurityPolicy,
    poll_runtime: poll_runtime.PollRuntime,
    providers: provider.ProviderRegistry,
    services: service_module.ServiceRegistry,
    poll_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, sdk: config.Sdk) RuntimeError!Runtime {
        const platform_config = sdk.configuration().platformConfig();
        platform_config.validate() catch return error.InvalidConfiguration;
        const policy = sdk.configuration().securityPolicy();
        try policy.validate();
        return .{
            .platform_config = platform_config,
            .security_policy = policy,
            .poll_runtime = poll_runtime.PollRuntime.init(allocator, sdk),
            .providers = try provider.ProviderRegistry.init(allocator, platform_config.limits.provider_capacity),
            .services = try service_module.ServiceRegistry.init(allocator, .{ .maximum_modules = platform_config.limits.service_capacity }),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.services.deinit();
        self.providers.deinit();
        self.poll_runtime.deinit();
        self.* = undefined;
    }

    pub fn registerProvider(self: *Runtime, item: provider.Provider) provider.ProviderRegistryError!void {
        try self.providers.register(item);
    }

    pub fn registerService(self: *Runtime, module: service_module.ServiceModule) service_module.ServiceModuleError!service_module.ServiceModuleId {
        return self.services.register(module);
    }

    pub fn start(self: *Runtime) RuntimeError!void {
        try self.security_policy.validate();
        try self.providers.start();
        errdefer for (self.providers.providers.items) |*registered| registered.stop();
        try self.security_policy.validateProviders(&self.providers);
        self.services.start() catch {
            return error.PollFailed;
        };
    }

    pub fn dispatchService(self: *Runtime, request: service_module.ServiceRequest) service_module.ServiceModuleError!service_module.ServiceDispatch {
        return self.services.dispatch(request);
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

    pub fn selectChannel(self: *const Runtime, descriptor: channel_delivery.ChannelDescriptor) RuntimeError!channel_delivery.ChannelBinding {
        try descriptor.validate();
        for (self.providers.providers.items, 0..) |registered, provider_index| {
            if (registered.state != .active) continue;
            const transport = try channel_delivery.provider_behavior(descriptor, registered.capabilities) orelse continue;
            return .{ .provider_index = provider_index, .transport = transport, .semantics = descriptor.semantics() };
        }
        return error.UnsupportedDelivery;
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
    stops: u8 = 0,
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
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        self.stops += 1;
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

test "unified runtimes select channel semantics from active provider capabilities" {
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    var fake = FakeProvider{ .capabilities = .{ .delivery_bits = core.delivery_capability_bit(.datagrams) } };
    try runtime.registerProvider(try fake.asProvider());
    try runtime.start();
    const binding = try runtime.selectChannel(.{ .delivery = .sequenced, .maximum_payload_bytes = 32, .maximum_in_flight = 2 });
    try std.testing.expectEqual(channel_delivery.ChannelTransport.datagram, binding.transport);
    try std.testing.expectError(error.UnsupportedDelivery, runtime.selectChannel(.{ .delivery = .stream, .maximum_payload_bytes = 32 }));
}

test "unified runtimes attach and dispatch bounded service modules" {
    const Fixture = struct {
        calls: usize = 0,

        fn route(context: ?*anyopaque, _: service_module.ServiceRequest) service_module.ServiceModuleError!service_module.ServiceRouteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .handled;
        }
    };
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .service_capacity = 1 } }).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    var fixture = Fixture{};
    _ = try runtime.registerService(.{ .config = .{ .name = "fixture", .route_prefix = "/fixture", .maximum_state_bytes = 8 }, .context = &fixture, .hooks = .{ .route = Fixture.route } });
    try runtime.start();
    const dispatch = try runtime.dispatchService(.{ .route = "/fixture/request", .credentials = "", .payload = "" });
    try std.testing.expectEqual(@as(usize, 0), dispatch.module);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "runtime security policies validate production providers and credentials before service startup" {
    const CredentialFixture = struct {
        calls: usize = 0,

        fn validate(context: ?*anyopaque, request: security_policy.SecurityCredentialRequest) security_policy.SecurityPolicyError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, request.provider_name, "runtime-fake")) return error.CredentialRejected;
            self.calls += 1;
        }
    };
    const ServiceFixture = struct {
        starts: usize = 0,

        fn initialize(context: ?*anyopaque) service_module.ServiceModuleError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.starts += 1;
        }

        fn route(_: ?*anyopaque, _: service_module.ServiceRequest) service_module.ServiceModuleError!service_module.ServiceRouteResult {
            return .handled;
        }
    };
    var manual = core.ManualClock.init(0);
    var credentials = CredentialFixture{};
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_security_policy(.{
        .environment = .production,
        .prohibit_plaintext = true,
        .require_tls = true,
        .require_credentials = true,
        .required_cipher_bits = core.cipher_capability_bit(.aes_256_gcm),
        .credential_context = &credentials,
        .credential_callback = CredentialFixture.validate,
    }).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    var fake = FakeProvider{ .capabilities = .{ .security_bits = core.security_capability_bit(.tls), .cipher_bits = core.cipher_capability_bit(.aes_256_gcm) } };
    try runtime.registerProvider(try fake.asProvider());
    var service = ServiceFixture{};
    _ = try runtime.registerService(.{ .config = .{ .name = "secure", .route_prefix = "/secure", .maximum_state_bytes = 1 }, .context = &service, .hooks = .{ .initialize = ServiceFixture.initialize, .route = ServiceFixture.route } });
    try runtime.start();
    try std.testing.expectEqual(@as(usize, 1), credentials.calls);
    try std.testing.expectEqual(@as(usize, 1), service.starts);
}

test "runtime security policies stop providers before unsafe services start" {
    const allow_credentials = struct {
        fn validate(_: ?*anyopaque, _: security_policy.SecurityCredentialRequest) security_policy.SecurityPolicyError!void {}
    }.validate;
    const ServiceFixture = struct {
        starts: usize = 0,

        fn initialize(context: ?*anyopaque) service_module.ServiceModuleError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.starts += 1;
        }

        fn route(_: ?*anyopaque, _: service_module.ServiceRequest) service_module.ServiceModuleError!service_module.ServiceRouteResult {
            return .handled;
        }
    };
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_security_policy(.{
        .environment = .production,
        .prohibit_plaintext = true,
        .require_tls = true,
        .require_credentials = true,
        .required_cipher_bits = core.cipher_capability_bit(.aes_256_gcm),
        .credential_callback = allow_credentials,
    }).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    var fake = FakeProvider{};
    try runtime.registerProvider(try fake.asProvider());
    var service = ServiceFixture{};
    _ = try runtime.registerService(.{ .config = .{ .name = "blocked", .route_prefix = "/blocked", .maximum_state_bytes = 1 }, .context = &service, .hooks = .{ .initialize = ServiceFixture.initialize, .route = ServiceFixture.route } });
    try std.testing.expectError(error.ProviderConstraintUnsatisfied, runtime.start());
    try std.testing.expectEqual(@as(u8, 1), fake.stops);
    try std.testing.expectEqual(@as(usize, 0), service.starts);
}
