const std = @import("std");
const core = @import("minna-san-core");
const topology = @import("minna-san-topology");
const transport_api = @import("minna-san-transport");
const config = @import("sdk_config.zig");
const event = @import("event.zig");
const poll_runtime = @import("poll_runtime.zig");
const provider = @import("provider.zig");
const resource_handle = @import("resource_handle.zig");
const session_registry = @import("session_registry.zig");
const channel_registry = @import("channel_registry.zig");
const timer_wheel = @import("timer_wheel.zig");
const payload_pool = @import("payload_pool.zig");
const channel_delivery = @import("channel_delivery.zig");
const service_module = @import("service_module.zig");
const security_policy = @import("security_policy.zig");
const tcp_channel_registry = @import("tcp_channel_registry.zig");
const tcp_fallback_registry = @import("tcp_fallback_registry.zig");
const tcp_listener_registry = @import("tcp_listener_registry.zig");
const tcp_session_registry = @import("tcp_session_registry.zig");
const udp_listener_registry = @import("udp_listener_registry.zig");
const udp_session_registry = @import("udp_session_registry.zig");

pub const RuntimeError = std.mem.Allocator.Error || poll_runtime.PollRuntimeError || provider.ProviderRegistryError || resource_handle.HandleError || session_registry.SessionRegistryError || channel_registry.ChannelRegistryError || tcp_channel_registry.TcpChannelRegistryError || tcp_fallback_registry.TcpFallbackRegistryError || tcp_listener_registry.TcpListenerRegistryError || tcp_session_registry.TcpSessionRegistryError || udp_listener_registry.UdpListenerError || udp_session_registry.UdpSessionError || timer_wheel.TimerWheelError || topology.RouteSelectionError || topology.RouteCandidateSelectionError || channel_delivery.ChannelDeliveryError || service_module.ServiceModuleError || security_policy.SecurityPolicyError || error{ReentrantPoll};

pub const UdpReadinessTarget = union(enum) {
    listener: *resource_handle.ResourceHandle,
    session: *resource_handle.ResourceHandle,
};

pub const UdpReadinessEvent = struct {
    target: UdpReadinessTarget,
    readable: bool = false,
    socket_error: bool = false,
    socket_hangup: bool = false,
    invalid_socket: bool = false,
};

pub const RuntimePollResult = struct {
    progress: poll_runtime.PollProgress = .idle,
    provider_work_completed: usize = 0,
    next_deadline: ?core.TimeNs = null,
    event: ?event.EventEnvelope = null,
    timer: ?timer_wheel.Timer = null,
    udp_readiness: ?UdpReadinessEvent = null,

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
    resources: *resource_handle.ResourceRegistry,
    sessions: *session_registry.SessionRegistry,
    channels: *channel_registry.ChannelRegistry,
    tcp_channels: tcp_channel_registry.TcpChannelRegistry,
    tcp_fallbacks: tcp_fallback_registry.TcpFallbackRegistry,
    tcp_listeners: tcp_listener_registry.TcpListenerRegistry,
    tcp_sessions: tcp_session_registry.TcpSessionRegistry,
    listeners: udp_listener_registry.UdpListenerRegistry,
    udp_sessions: udp_session_registry.UdpSessionRegistry,
    payloads: *payload_pool.PayloadPool,
    timers: timer_wheel.TimerWheel,
    services: service_module.ServiceRegistry,
    poll_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, sdk: config.Sdk) RuntimeError!Runtime {
        const platform_config = sdk.configuration().platformConfig();
        platform_config.validate() catch return error.InvalidConfiguration;
        const policy = sdk.configuration().securityPolicy();
        try policy.validate();
        const session_and_channel_capacity = std.math.add(usize, platform_config.limits.session_capacity, platform_config.limits.channel_capacity) catch return error.InvalidConfiguration;
        const resource_capacity = std.math.add(usize, session_and_channel_capacity, platform_config.limits.listener_capacity) catch return error.InvalidConfiguration;
        const resources = try allocator.create(resource_handle.ResourceRegistry);
        errdefer allocator.destroy(resources);
        resources.* = try resource_handle.ResourceRegistry.init(allocator, resource_capacity);
        errdefer resources.deinit();
        const sessions = try allocator.create(session_registry.SessionRegistry);
        errdefer allocator.destroy(sessions);
        sessions.* = try session_registry.SessionRegistry.init(allocator, resources, platform_config.limits.session_capacity);
        errdefer sessions.deinit();
        const payloads = try allocator.create(payload_pool.PayloadPool);
        errdefer allocator.destroy(payloads);
        payloads.* = try payload_pool.PayloadPool.init(allocator, platform_config.limits.channel_capacity, platform_config.limits.payload_pool_bytes);
        errdefer payloads.deinit();
        const channels = try allocator.create(channel_registry.ChannelRegistry);
        errdefer allocator.destroy(channels);
        channels.* = try channel_registry.ChannelRegistry.init(allocator, resources, sessions, payloads, platform_config.limits.channel_capacity);
        errdefer channels.deinit();
        var tcp_listeners = try tcp_listener_registry.TcpListenerRegistry.init(allocator, resources, platform_config.limits.listener_capacity);
        errdefer tcp_listeners.deinit();
        var tcp_sessions = try tcp_session_registry.TcpSessionRegistry.init(allocator, sessions, platform_config.limits.session_capacity);
        errdefer tcp_sessions.deinit();
        var tcp_channels = try tcp_channel_registry.TcpChannelRegistry.init(allocator, &tcp_sessions, channels, platform_config.limits.session_capacity);
        errdefer tcp_channels.deinit();
        var tcp_fallbacks = try tcp_fallback_registry.TcpFallbackRegistry.init(allocator, platform_config.limits.session_capacity);
        errdefer tcp_fallbacks.deinit();
        var listeners = try udp_listener_registry.UdpListenerRegistry.init(allocator, resources, platform_config.limits.listener_capacity);
        errdefer listeners.deinit();
        var udp_sessions = try udp_session_registry.UdpSessionRegistry.init(allocator, sessions, channels, platform_config.limits.session_capacity);
        errdefer udp_sessions.deinit();
        var timers = try timer_wheel.TimerWheel.init(allocator, platform_config.limits.event_capacity);
        errdefer timers.deinit();
        var providers = try provider.ProviderRegistry.init(allocator, platform_config.limits.provider_capacity);
        errdefer providers.deinit();
        var services = try service_module.ServiceRegistry.init(allocator, .{ .maximum_modules = platform_config.limits.service_capacity });
        errdefer services.deinit();
        return .{
            .platform_config = platform_config,
            .security_policy = policy,
            .poll_runtime = poll_runtime.PollRuntime.init(allocator, sdk),
            .providers = providers,
            .resources = resources,
            .sessions = sessions,
            .channels = channels,
            .tcp_channels = tcp_channels,
            .tcp_fallbacks = tcp_fallbacks,
            .tcp_listeners = tcp_listeners,
            .tcp_sessions = tcp_sessions,
            .listeners = listeners,
            .udp_sessions = udp_sessions,
            .payloads = payloads,
            .timers = timers,
            .services = services,
        };
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.resources.allocator;
        self.services.deinit();
        self.providers.deinit();
        self.timers.deinit();
        self.tcp_channels.deinit();
        self.tcp_fallbacks.deinit();
        self.tcp_sessions.deinit();
        self.udp_sessions.deinit();
        self.listeners.deinit();
        self.tcp_listeners.deinit();
        self.channels.deinit();
        allocator.destroy(self.channels);
        self.payloads.deinit();
        allocator.destroy(self.payloads);
        self.sessions.deinit();
        allocator.destroy(self.sessions);
        self.resources.deinit();
        allocator.destroy(self.resources);
        self.poll_runtime.deinit();
        self.* = undefined;
    }

    pub fn registerProvider(self: *Runtime, item: provider.Provider) provider.ProviderRegistryError!void {
        try self.providers.register(item);
    }

    pub fn acquireResource(self: *Runtime, kind: resource_handle.ResourceKind) resource_handle.HandleError!*resource_handle.ResourceHandle {
        return self.resources.acquire_kind(kind);
    }

    pub fn releaseResource(self: *Runtime, handle: *resource_handle.ResourceHandle, kind: resource_handle.ResourceKind) resource_handle.HandleError!void {
        try self.resources.release_kind(handle, kind);
    }

    pub fn createSession(self: *Runtime) session_registry.SessionRegistryError!*resource_handle.ResourceHandle {
        return self.sessions.create();
    }

    pub fn session(self: *Runtime, handle: *resource_handle.ResourceHandle) session_registry.SessionRegistryError!*session_registry.SessionLifecycle {
        return self.sessions.lookup(handle);
    }

    pub fn transitionSession(self: *Runtime, handle: *resource_handle.ResourceHandle, action: session_registry.SessionTransition) session_registry.SessionRegistryError!void {
        try self.sessions.transition(handle, action);
    }

    pub fn closeSession(self: *Runtime, handle: *resource_handle.ResourceHandle) session_registry.SessionRegistryError!void {
        try self.sessions.close(handle);
    }

    pub fn createChannel(self: *Runtime, owner: *resource_handle.ResourceHandle, descriptor: channel_delivery.ChannelDescriptor) channel_registry.ChannelRegistryError!*resource_handle.ResourceHandle {
        return self.channels.create(owner, descriptor);
    }

    pub fn enqueueChannel(self: *Runtime, handle: *resource_handle.ResourceHandle, payload: []const u8) channel_registry.ChannelRegistryError!void {
        try self.channels.enqueue(handle, payload);
    }

    pub fn dequeueChannel(self: *Runtime, owner: *resource_handle.ResourceHandle) channel_registry.ChannelRegistryError!?channel_registry.QueuedMessage {
        return self.channels.dequeue(owner);
    }

    pub fn teardownChannel(self: *Runtime, handle: *resource_handle.ResourceHandle) channel_registry.ChannelRegistryError!void {
        try self.channels.teardown(handle);
    }

    pub fn openTcpListener(self: *Runtime, config_value: tcp_listener_registry.TcpListenerConfig) tcp_listener_registry.TcpListenerRegistryError!*resource_handle.ResourceHandle {
        return self.tcp_listeners.open(config_value);
    }

    pub fn pollTcpListener(self: *Runtime, handle: *resource_handle.ResourceHandle) tcp_listener_registry.TcpListenerRegistryError!tcp_listener_registry.TcpListenerPoll {
        return self.tcp_listeners.poll(handle);
    }

    pub fn acceptTcpListener(self: *Runtime, handle: *resource_handle.ResourceHandle) tcp_listener_registry.TcpListenerRegistryError!?tcp_listener_registry.TcpListenerAccept {
        return self.tcp_listeners.accept(handle);
    }

    pub fn tcpListenerAddress(self: *Runtime, handle: *resource_handle.ResourceHandle) tcp_listener_registry.TcpListenerRegistryError!transport_api.Ipv4Address {
        return self.tcp_listeners.localAddress(handle);
    }

    pub fn closeTcpListener(self: *Runtime, handle: *resource_handle.ResourceHandle) tcp_listener_registry.TcpListenerRegistryError!void {
        try self.tcp_listeners.close(handle);
    }

    pub fn dialTcp(self: *Runtime, config_value: tcp_session_registry.TcpDialConfig) tcp_session_registry.TcpSessionRegistryError!*resource_handle.ResourceHandle {
        return self.tcp_sessions.dial(config_value);
    }

    pub fn pollTcpSession(self: *Runtime, handle: *resource_handle.ResourceHandle, elapsed_ms: u32) tcp_session_registry.TcpSessionRegistryError!tcp_session_registry.TcpSessionPoll {
        return self.tcp_sessions.poll(handle, elapsed_ms);
    }

    pub fn cancelTcpSession(self: *Runtime, handle: *resource_handle.ResourceHandle) tcp_session_registry.TcpSessionRegistryError!void {
        try self.tcp_sessions.cancel(handle);
    }

    pub fn closeTcpSession(self: *Runtime, handle: *resource_handle.ResourceHandle) RuntimeError!void {
        self.tcp_channels.detachSession(handle) catch |err| switch (err) {
            error.UnknownSession => {},
            else => return err,
        };
        try self.tcp_sessions.close(handle);
    }

    pub fn adoptTcpConnection(self: *Runtime, connection: *transport_api.TcpConnection, peer: transport_api.Ipv4Address) tcp_session_registry.TcpSessionRegistryError!*resource_handle.ResourceHandle {
        return self.tcp_sessions.adopt(connection, peer);
    }

    pub fn attachTcpChannel(self: *Runtime, session_handle: *resource_handle.ResourceHandle, descriptor: channel_delivery.ChannelDescriptor) tcp_channel_registry.TcpChannelRegistryError!*resource_handle.ResourceHandle {
        return self.tcp_channels.attach(session_handle, descriptor);
    }

    pub fn flushTcpChannel(self: *Runtime, session_handle: *resource_handle.ResourceHandle) tcp_channel_registry.TcpChannelRegistryError!tcp_channel_registry.TcpChannelFlush {
        return self.tcp_channels.flush(session_handle);
    }

    pub fn receiveTcpChannel(self: *Runtime, session_handle: *resource_handle.ResourceHandle) tcp_channel_registry.TcpChannelRegistryError!?tcp_channel_registry.TcpChannelReceive {
        return self.tcp_channels.receive(session_handle);
    }

    pub fn openUdpListener(self: *Runtime, config_value: udp_listener_registry.UdpListenerConfig) udp_listener_registry.UdpListenerError!*resource_handle.ResourceHandle {
        return self.listeners.open(config_value);
    }

    pub fn pollUdpListener(self: *Runtime, handle: *resource_handle.ResourceHandle) udp_listener_registry.UdpListenerError!udp_listener_registry.UdpListenerPoll {
        return self.listeners.poll(handle);
    }

    pub fn udpListenerAddress(self: *Runtime, handle: *resource_handle.ResourceHandle) udp_listener_registry.UdpListenerError!transport_api.ResolvedAddress {
        return self.listeners.localAddress(handle);
    }

    pub fn closeUdpListener(self: *Runtime, handle: *resource_handle.ResourceHandle) udp_listener_registry.UdpListenerError!void {
        try self.listeners.close(handle);
    }

    pub fn dialUdp(self: *Runtime, config_value: udp_session_registry.UdpDialConfig) udp_session_registry.UdpSessionError!*resource_handle.ResourceHandle {
        return self.udp_sessions.dial(config_value);
    }

    pub fn pollUdpSession(self: *Runtime, handle: *resource_handle.ResourceHandle) udp_session_registry.UdpSessionError!udp_session_registry.UdpSessionPoll {
        return self.udp_sessions.poll(handle);
    }

    pub fn closeUdpSession(self: *Runtime, handle: *resource_handle.ResourceHandle) udp_session_registry.UdpSessionError!void {
        self.tcp_fallbacks.forget(handle);
        try self.udp_sessions.close(handle);
    }

    pub fn registerTcpFallback(self: *Runtime, udp_session: *resource_handle.ResourceHandle, policy: topology.RouteCandidatePolicy) RuntimeError!void {
        try self.udp_sessions.validateSession(udp_session);
        try self.tcp_fallbacks.register(udp_session, policy);
    }

    pub fn selectTcpFallback(self: *Runtime, udp_session: *resource_handle.ResourceHandle, failure: tcp_fallback_registry.UdpFallbackFailure, candidates: []const topology.RouteCandidate) RuntimeError!tcp_fallback_registry.TcpFallbackEvent {
        const policy = try self.tcp_fallbacks.policy(udp_session);
        if (!self.providers.supportsRequirements(policy.required_capabilities)) return error.UnsupportedCapabilities;
        return self.tcp_fallbacks.select(udp_session, failure, candidates);
    }

    pub fn listTcpFallbackTransitions(self: *Runtime, udp_session: *resource_handle.ResourceHandle, output: []tcp_fallback_registry.TcpFallbackTransition) RuntimeError!usize {
        return self.tcp_fallbacks.listTransitions(udp_session, output);
    }

    pub fn pollUdpReceives(self: *Runtime, handle: *resource_handle.ResourceHandle, events: []udp_session_registry.UdpReceiveEvent) udp_session_registry.UdpSessionError!udp_session_registry.UdpReceiveBatch {
        return self.udp_sessions.pollReceives(handle, events);
    }

    pub fn flushUdpSends(self: *Runtime, handle: *resource_handle.ResourceHandle, events: []udp_session_registry.UdpSendEvent) udp_session_registry.UdpSessionError!udp_session_registry.UdpSendBatch {
        return self.udp_sessions.flushSends(handle, events);
    }

    pub fn nextUdpPathMtuProbe(self: *Runtime, handle: *resource_handle.ResourceHandle) udp_session_registry.UdpSessionError!?usize {
        return self.udp_sessions.nextPathMtuProbe(handle);
    }

    pub fn recordUdpPathMtuProbe(self: *Runtime, handle: *resource_handle.ResourceHandle, payload: usize, delivered: bool) udp_session_registry.UdpSessionError!usize {
        return self.udp_sessions.recordPathMtuProbe(handle, payload, delivered);
    }

    pub fn udpSessionAddress(self: *Runtime, handle: *resource_handle.ResourceHandle) udp_session_registry.UdpSessionError!transport_api.ResolvedAddress {
        return self.udp_sessions.localAddress(handle);
    }

    pub fn pollUdpReadiness(self: *Runtime) RuntimeError!?UdpReadinessEvent {
        if (try self.listeners.pollNextReadiness()) |value| {
            return .{ .target = .{ .listener = value.listener }, .readable = value.poll.readable, .socket_error = value.poll.socket_error, .socket_hangup = value.poll.socket_hangup, .invalid_socket = value.poll.invalid_socket };
        }
        if (try self.udp_sessions.pollNextReadiness()) |value| {
            return .{ .target = .{ .session = value.session }, .readable = value.readable, .socket_error = value.socket_error, .socket_hangup = value.socket_hangup, .invalid_socket = value.invalid_socket };
        }
        return null;
    }

    pub fn scheduleTimer(self: *Runtime, kind: timer_wheel.TimerKind, deadline_ns: core.TimeNs) timer_wheel.TimerWheelError!timer_wheel.TimerId {
        return self.timers.schedule(kind, deadline_ns);
    }

    pub fn cancelTimer(self: *Runtime, id: timer_wheel.TimerId) timer_wheel.TimerWheelError!void {
        try self.timers.cancel(id);
    }

    pub fn payloadPressure(self: *const Runtime) payload_pool.PayloadPoolPressure {
        return self.payloads.pressure();
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
        const provider_result = try self.providers.poll(input.now_ns, @min(input.work_budget, self.platform_config.limits.poll_work_budget));
        const timer = try self.timers.advance(input.now_ns);
        const udp_readiness = try self.pollUdpReadiness();
        var outcome = try self.poll_runtime.poll(input);
        errdefer outcome.deinit();
        var next_deadline = outcome.next_deadline;
        if (provider_result.next_deadline) |deadline| next_deadline = if (next_deadline) |current| @min(current, deadline) else deadline;
        if (self.timers.nextDeadline()) |deadline| next_deadline = if (next_deadline) |current| @min(current, deadline) else deadline;
        const progress: poll_runtime.PollProgress = if (outcome.event != null) .event else if (provider_result.work_completed > 0) .provider else if (timer != null) .deadline else if (udp_readiness != null) .udp else .idle;
        const result = RuntimePollResult{
            .progress = progress,
            .provider_work_completed = provider_result.work_completed,
            .next_deadline = next_deadline,
            .event = outcome.event,
            .timer = timer,
            .udp_readiness = udp_readiness,
        };
        outcome.event = null;
        return result;
    }
};

const FakeProvider = struct {
    name: []const u8 = "runtime-fake",
    polls: u8 = 0,
    stops: u8 = 0,
    capabilities: provider.ProviderCapabilityDescriptor = .{},

    fn asProvider(self: *FakeProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = self.name }, self, .{ .init = init, .query_capabilities = queryCapabilities, .poll = poll, .teardown = teardown });
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

test "unified runtimes rotate bounded provider work and expose due timers" {
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 2, .poll_work_budget = 1 } }).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    var first = FakeProvider{ .name = "first" };
    var second = FakeProvider{ .name = "second" };
    try runtime.registerProvider(try first.asProvider());
    try runtime.registerProvider(try second.asProvider());
    try runtime.start();
    _ = try runtime.scheduleTimer(.session, 1);
    var initial = try runtime.poll(.{ .now_ns = 0, .work_budget = 1 });
    defer initial.deinit();
    try std.testing.expectEqual(@as(u8, 1), first.polls);
    try std.testing.expectEqual(@as(u8, 0), second.polls);
    var due = try runtime.poll(.{ .now_ns = 1, .work_budget = 1 });
    defer due.deinit();
    try std.testing.expectEqual(@as(u8, 1), second.polls);
    try std.testing.expectEqual(timer_wheel.TimerKind.session, due.timer.?.kind);
}

test "unified runtimes own bounded resource registries and empty teardown" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 2, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        try std.testing.expectEqual(@as(usize, 4), runtime.resources.slots.len);
        const session = try runtime.acquireResource(.session);
        try runtime.resources.validate_kind(session, .session);
        try runtime.releaseResource(session, .session);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes own UDP listener handles without descriptor leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        const listener = try runtime.openUdpListener(.{ .endpoint = transport_api.Endpoint.from_ipv4(transport_api.Ipv4Address.wildcard(0)) });
        const local = try runtime.udpListenerAddress(listener);
        switch (local) {
            .ipv4 => |address| try std.testing.expect(address.port != 0),
            .ipv6 => unreachable,
        }
        try std.testing.expect(!(try runtime.pollUdpListener(listener)).readable);
        try runtime.closeUdpListener(listener);
        try std.testing.expectError(error.StaleHandle, runtime.pollUdpListener(listener));
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes own TCP listener handles and accepted connections" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        const listener = try runtime.openTcpListener(.{ .endpoint = transport_api.Ipv4Address.wildcard(0), .backlog = 1 });
        const endpoint = try transport_api.Ipv4Address.parse("127.0.0.1", (try runtime.tcpListenerAddress(listener)).port);
        var client = try transport_api.TcpConnection.init();
        defer if (client.state != .closed) client.close();
        _ = try client.start_connect(endpoint, 1_000);
        var accepted: ?tcp_listener_registry.TcpListenerAccept = null;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if ((try runtime.pollTcpListener(listener)).readable) accepted = try runtime.acceptTcpListener(listener);
            if (accepted != null) break;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        var connection = accepted orelse return error.TestExpectedEqual;
        defer connection.connection.close();
        try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, connection.peer.octets);
        try runtime.closeTcpListener(listener);
        try std.testing.expectError(error.StaleHandle, runtime.pollTcpListener(listener));
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes establish and close TCP sessions under explicit polling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        const listener = try runtime.openTcpListener(.{ .endpoint = transport_api.Ipv4Address.wildcard(0), .backlog = 1 });
        const endpoint = try transport_api.Ipv4Address.parse("127.0.0.1", (try runtime.tcpListenerAddress(listener)).port);
        const session = try runtime.dialTcp(.{ .endpoint = transport_api.Endpoint.from_ipv4(endpoint), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .timeout_ms = 1_000 });
        var accepted: ?tcp_listener_registry.TcpListenerAccept = null;
        defer if (accepted) |*connection| connection.connection.close();
        var established = false;
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < 100) : (elapsed_ms += 1) {
            if ((try runtime.pollTcpListener(listener)).readable) accepted = try runtime.acceptTcpListener(listener);
            const result = try runtime.pollTcpSession(session, elapsed_ms);
            if (result.outcome == .ready) {
                established = true;
                break;
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(established);
        try runtime.closeTcpSession(session);
        try runtime.closeTcpListener(listener);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes frame TCP channel messages through owned buffers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var first_clock = core.ManualClock.init(0);
        var second_clock = core.ManualClock.init(0);
        const first_sdk = try config.SdkConfigBuilder.init().with_clock(first_clock.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        const second_sdk = try config.SdkConfigBuilder.init().with_clock(second_clock.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var client = try Runtime.init(allocator, first_sdk);
        defer client.deinit();
        var server = try Runtime.init(allocator, second_sdk);
        defer server.deinit();
        const listener = try server.openTcpListener(.{ .endpoint = transport_api.Ipv4Address.wildcard(0), .backlog = 1 });
        const endpoint = try transport_api.Ipv4Address.parse("127.0.0.1", (try server.tcpListenerAddress(listener)).port);
        const client_session = try client.dialTcp(.{ .endpoint = transport_api.Endpoint.from_ipv4(endpoint), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .timeout_ms = 1_000 });
        var accepted: ?tcp_listener_registry.TcpListenerAccept = null;
        var connected = false;
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < 100) : (elapsed_ms += 1) {
            if ((try server.pollTcpListener(listener)).readable) accepted = try server.acceptTcpListener(listener);
            if ((try client.pollTcpSession(client_session, elapsed_ms)).outcome == .ready and accepted != null) {
                connected = true;
                break;
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(connected);
        var pending = accepted orelse return error.TestExpectedEqual;
        const server_session = try server.adoptTcpConnection(&pending.connection, pending.peer);
        const descriptor = channel_delivery.ChannelDescriptor{ .delivery = .stream, .maximum_payload_bytes = 64 };
        const client_channel = try client.attachTcpChannel(client_session, descriptor);
        _ = try server.attachTcpChannel(server_session, descriptor);
        try client.enqueueChannel(client_channel, "frame");
        var sent = false;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if ((try client.flushTcpChannel(client_session)).sent) {
                sent = true;
                break;
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(sent);
        var received: ?tcp_channel_registry.TcpChannelReceive = null;
        attempts = 0;
        while (attempts < 100) : (attempts += 1) {
            received = try server.receiveTcpChannel(server_session);
            if (received != null) break;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        var message = received orelse return error.TestExpectedEqual;
        defer message.deinit(allocator);
        try std.testing.expectEqualStrings("frame", message.message.payload);
        try client.closeTcpSession(client_session);
        try server.closeTcpSession(server_session);
        try server.closeTcpListener(listener);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes establish localhost UDP sessions under explicit polling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var first_clock = core.ManualClock.init(0);
        var second_clock = core.ManualClock.init(0);
        const first_sdk = try config.SdkConfigBuilder.init().with_clock(first_clock.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        const second_sdk = try config.SdkConfigBuilder.init().with_clock(second_clock.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var first = try Runtime.init(allocator, first_sdk);
        defer first.deinit();
        var second = try Runtime.init(allocator, second_sdk);
        defer second.deinit();
        const first_listener = try first.openUdpListener(.{ .endpoint = transport_api.Endpoint.from_ipv4(transport_api.Ipv4Address.wildcard(0)) });
        const second_listener = try second.openUdpListener(.{ .endpoint = transport_api.Endpoint.from_ipv4(transport_api.Ipv4Address.wildcard(0)) });
        const first_address = switch (try first.udpListenerAddress(first_listener)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        const second_address = switch (try second.udpListenerAddress(second_listener)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        const descriptor = channel_delivery.ChannelDescriptor{ .delivery = .datagram, .maximum_payload_bytes = 64, .maximum_in_flight = 1 };
        const first_session = try first.dialUdp(.{ .endpoint = transport_api.Endpoint.from_ipv4(second_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = descriptor });
        const second_session = try second.dialUdp(.{ .endpoint = transport_api.Endpoint.from_ipv4(first_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = descriptor });
        try std.testing.expectEqual(session_registry.SessionState.ready, (try first.pollUdpSession(first_session)).state);
        try std.testing.expectEqual(session_registry.SessionState.ready, (try second.pollUdpSession(second_session)).state);
        try first.closeUdpSession(first_session);
        try second.closeUdpSession(second_session);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes select policy-permitted TCP fallback in ordered session transitions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        var receiver = try transport_api.UdpSocket.init(.{});
        defer receiver.close();
        try receiver.bind(try transport_api.Ipv4Address.parse("127.0.0.1", 0));
        const receiver_address = local_udp_ipv4_address(&receiver);
        const udp_session = try runtime.dialUdp(.{ .endpoint = transport_api.Endpoint.from_ipv4(receiver_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64 } });
        try runtime.registerTcpFallback(udp_session, .{ .allowed_transport_bits = topology.route_transport_bit(.udp) | topology.route_transport_bit(.tcp) });
        const candidates = [_]topology.RouteCandidate{
            .{ .id = 1, .transport = .udp, .endpoint = transport_api.Endpoint.from_ipv4(receiver_address), .negotiated = true, .health = .healthy },
            .{ .id = 2, .transport = .tcp, .endpoint = transport_api.Endpoint.from_ipv4(receiver_address), .negotiated = true, .health = .healthy },
        };
        const fallback = try runtime.selectTcpFallback(udp_session, .send_failed, candidates[0..]);
        try std.testing.expectEqual(@as(u64, 1), fallback.sequence);
        try std.testing.expectEqual(@as(u64, 2), fallback.candidate.candidate.id);
        var transitions: [2]tcp_fallback_registry.TcpFallbackTransition = undefined;
        try std.testing.expectEqual(@as(usize, 2), try runtime.listTcpFallbackTransitions(udp_session, transitions[0..]));
        try std.testing.expectEqual(@as(u64, 0), transitions[0].sequence);
        try std.testing.expectEqual(tcp_fallback_registry.TcpFallbackTransitionKind.udp_failed, transitions[0].kind);
        try std.testing.expectEqual(@as(u64, 1), transitions[1].sequence);
        try std.testing.expectEqual(tcp_fallback_registry.TcpFallbackTransitionKind.downgraded_to_tcp, transitions[1].kind);
        try runtime.closeUdpSession(udp_session);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes receive ordered UDP batches into owned channels" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 3, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        var sender = try transport_api.UdpSocket.init(.{});
        defer sender.close();
        try sender.bind(try transport_api.Ipv4Address.parse("127.0.0.1", 0));
        const sender_address = local_udp_ipv4_address(&sender);
        const session = try runtime.dialUdp(.{ .endpoint = transport_api.Endpoint.from_ipv4(sender_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64, .maximum_in_flight = 3 } });
        _ = try runtime.pollUdpSession(session);
        const destination = switch (try runtime.udpSessionAddress(session)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        _ = try sender.send_to("one", destination);
        _ = try sender.send_to("two", destination);
        _ = try sender.send_to("three", destination);
        var events: [3]udp_session_registry.UdpReceiveEvent = undefined;
        var received: usize = 0;
        var attempts: usize = 0;
        while (received < events.len and attempts < 100) : (attempts += 1) {
            const batch = try runtime.pollUdpReceives(session, events[received..]);
            received += batch.received;
            if (batch.would_block) std.Thread.sleep(std.time.ns_per_ms);
        }
        try std.testing.expectEqual(events.len, received);
        for (events, 0..) |item, index| {
            try std.testing.expectEqual(@as(u64, @intCast(index)), item.sequence);
            try std.testing.expectEqual(session, item.session);
            try std.testing.expectEqual(sender_address, switch (item.source) {
                .ipv4 => |address| address,
                .ipv6 => unreachable,
            });
        }
        var first = (try runtime.dequeueChannel(session)).?;
        defer first.deinit(allocator);
        var second = (try runtime.dequeueChannel(session)).?;
        defer second.deinit(allocator);
        var third = (try runtime.dequeueChannel(session)).?;
        defer third.deinit(allocator);
        try std.testing.expectEqualStrings("one", first.payload);
        try std.testing.expectEqualStrings("two", second.payload);
        try std.testing.expectEqualStrings("three", third.payload);
        try runtime.closeUdpSession(session);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes flush scheduled UDP datagrams by priority" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 2, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        var receiver = try transport_api.UdpSocket.init(.{});
        defer receiver.close();
        try receiver.bind(try transport_api.Ipv4Address.parse("127.0.0.1", 0));
        const receiver_address = local_udp_ipv4_address(&receiver);
        const session = try runtime.dialUdp(.{ .endpoint = transport_api.Endpoint.from_ipv4(receiver_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .priority = 0, .maximum_payload_bytes = 64 } });
        const primary = (try runtime.pollUdpSession(session)).channel;
        const high = try runtime.createChannel(session, .{ .delivery = .datagram, .priority = 1, .maximum_payload_bytes = 64 });
        try runtime.enqueueChannel(primary, "primary");
        try runtime.enqueueChannel(high, "high");
        var events: [2]udp_session_registry.UdpSendEvent = undefined;
        const batch = try runtime.flushUdpSends(session, events[0..]);
        try std.testing.expectEqual(@as(usize, 2), batch.sent);
        try std.testing.expectEqual(@as(usize, 0), batch.remaining);
        try std.testing.expectEqual(high, events[0].channel);
        try std.testing.expectEqual(primary, events[1].channel);
        try runtime.teardownChannel(high);
        try runtime.closeUdpSession(session);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtimes apply path-MTU loss before UDP sends" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        var receiver = try transport_api.UdpSocket.init(.{});
        defer receiver.close();
        try receiver.bind(try transport_api.Ipv4Address.parse("127.0.0.1", 0));
        const receiver_address = local_udp_ipv4_address(&receiver);
        const session = try runtime.dialUdp(.{ .endpoint = transport_api.Endpoint.from_ipv4(receiver_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 128 }, .path_mtu = .{ .minimum_payload = 64, .maximum_payload = 128 } });
        const primary = (try runtime.pollUdpSession(session)).channel;
        const oversized = [_]u8{0} ** 97;
        try runtime.enqueueChannel(primary, &oversized);
        const probe = (try runtime.nextUdpPathMtuProbe(session)).?;
        try std.testing.expectEqual(@as(usize, 95), try runtime.recordUdpPathMtuProbe(session, probe, false));
        try std.testing.expectError(error.PayloadTooLarge, runtime.enqueueChannel(primary, &oversized));
        var events: [1]udp_session_registry.UdpSendEvent = undefined;
        try std.testing.expectEqual(@as(usize, 1), (try runtime.flushUdpSends(session, events[0..])).dropped);
        try std.testing.expectEqual(transport_api.UdpSendStatus.datagram_too_large, events[0].status);
        try runtime.closeUdpSession(session);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtime polls UDP readiness without receiving datagrams" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        var sender = try transport_api.UdpSocket.init(.{});
        defer sender.close();
        try sender.bind(try transport_api.Ipv4Address.parse("127.0.0.1", 0));
        const sender_address = local_udp_ipv4_address(&sender);
        const session = try runtime.dialUdp(.{ .endpoint = transport_api.Endpoint.from_ipv4(sender_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64 } });
        _ = try runtime.pollUdpSession(session);
        var idle = try runtime.poll(.{ .now_ns = manual.clock().now() });
        defer idle.deinit();
        try std.testing.expectEqual(poll_runtime.PollProgress.idle, idle.progress);
        try std.testing.expect(idle.udp_readiness == null);
        const destination = switch (try runtime.udpSessionAddress(session)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        _ = try sender.send_to("ready", destination);
        var woke = false;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            var result = try runtime.poll(.{ .now_ns = manual.clock().now() });
            const progress = result.progress;
            const readiness = result.udp_readiness;
            result.deinit();
            if (readiness) |value| {
                try std.testing.expectEqual(poll_runtime.PollProgress.udp, progress);
                switch (value.target) {
                    .session => |handle| try std.testing.expectEqual(session, handle),
                    .listener => unreachable,
                }
                try std.testing.expect(value.readable);
                woke = true;
                break;
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(woke);
        var events: [1]udp_session_registry.UdpReceiveEvent = undefined;
        try std.testing.expectEqual(@as(usize, 1), (try runtime.pollUdpReceives(session, events[0..])).received);
        var message = (try runtime.dequeueChannel(session)).?;
        defer message.deinit(allocator);
        try std.testing.expectEqualStrings("ready", message.payload);
        try runtime.closeUdpSession(session);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "unified runtime polls UDP listener readiness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1, .listener_capacity = 1 } }).build();
        var runtime = try Runtime.init(allocator, configured_sdk);
        defer runtime.deinit();
        const listener = try runtime.openUdpListener(.{ .endpoint = transport_api.Endpoint.from_ipv4(transport_api.Ipv4Address.wildcard(0)) });
        const address = switch (try runtime.udpListenerAddress(listener)) {
            .ipv4 => |value| try transport_api.Ipv4Address.parse("127.0.0.1", value.port),
            .ipv6 => unreachable,
        };
        var sender = try transport_api.UdpSocket.init(.{});
        defer sender.close();
        _ = try sender.send_to("ready", address);
        var woke = false;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            var result = try runtime.poll(.{ .now_ns = manual.clock().now() });
            const progress = result.progress;
            const readiness = result.udp_readiness;
            result.deinit();
            if (readiness) |value| {
                try std.testing.expectEqual(poll_runtime.PollProgress.udp, progress);
                switch (value.target) {
                    .listener => |handle| try std.testing.expectEqual(listener, handle),
                    .session => unreachable,
                }
                try std.testing.expect(value.readable);
                woke = true;
                break;
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(woke);
        try runtime.closeUdpListener(listener);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

fn local_udp_ipv4_address(socket: *transport_api.UdpSocket) transport_api.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    std.posix.getsockname(socket.socket.handle, &native.any, &length) catch unreachable;
    return transport_api.Ipv4Address.from_native(native) catch unreachable;
}

test "unified runtimes store sessions on owned generation handles" {
    var manual = core.ManualClock.init(0);
    const configured_sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 1 } }).build();
    var runtime = try Runtime.init(std.testing.allocator, configured_sdk);
    defer runtime.deinit();
    const handle = try runtime.createSession();
    try runtime.transitionSession(handle, .begin_establishing);
    try runtime.transitionSession(handle, .begin_draining);
    try runtime.closeSession(handle);
    try std.testing.expectError(error.StaleHandle, runtime.session(handle));
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
