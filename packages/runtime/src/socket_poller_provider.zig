const std = @import("std");
const core = @import("minna-san-core");
const transport = @import("minna-san-transport");
const provider = @import("provider.zig");

pub const max_socket_poller_provider_registrations: usize = transport.max_socket_poll_targets;
pub const SocketPollerProviderError = provider.ProviderError || transport.SocketPollError || error{ InvalidConfiguration, Inactive, RegistrationCapacityExceeded, StaleRegistration, InvalidInterest, InvalidTarget };
pub const SocketPollerProviderConfig = struct {
    maximum_registrations: usize = max_socket_poller_provider_registrations,
    maximum_events: usize = max_socket_poller_provider_registrations,
    poll_work_budget: usize = 1,

    pub fn validate(self: SocketPollerProviderConfig) SocketPollerProviderError!void {
        if (self.maximum_registrations == 0 or self.maximum_registrations > max_socket_poller_provider_registrations or self.maximum_events == 0 or self.maximum_events > self.maximum_registrations or self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};
pub const SocketPollerRegistration = struct {
    provider_id: u32,
    slot: u8,
    generation: u32,
};
pub const SocketPollerProviderEvent = struct {
    sequence: u64,
    registration: SocketPollerRegistration,
    event: transport.SocketPollEvent,
};

const Slot = struct {
    generation: u32 = 1,
    target: ?transport.SocketPollTarget = null,
    interest: transport.SocketPollInterest = .{},
};

var next_provider_id = std.atomic.Value(u32).init(1);

pub const SocketPollerProvider = struct {
    config: SocketPollerProviderConfig,
    provider_id: u32,
    poller: ?transport.SocketPoller = null,
    slots: [max_socket_poller_provider_registrations]Slot = [_]Slot{.{}} ** max_socket_poller_provider_registrations,
    events: [max_socket_poller_provider_registrations]SocketPollerProviderEvent = undefined,
    event_start: usize = 0,
    event_count: usize = 0,
    next_event_sequence: u64 = 0,
    active: bool = false,

    pub fn init(config: SocketPollerProviderConfig) SocketPollerProviderError!SocketPollerProvider {
        try config.validate();
        const provider_id = next_provider_id.fetchAdd(1, .monotonic);
        if (provider_id == 0) return error.InvalidConfiguration;
        return .{ .config = config, .provider_id = provider_id };
    }

    pub fn deinit(self: *SocketPollerProvider) void {
        self.stop();
        self.* = undefined;
    }

    pub fn asProvider(self: *SocketPollerProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = "socket-poller", .poll_work_budget = self.config.poll_work_budget }, self, .{ .init = providerInit, .query_capabilities = queryCapabilities, .poll = providerPoll, .teardown = providerTeardown });
    }

    pub fn register(self: *SocketPollerProvider, target: transport.SocketPollTarget, interest: transport.SocketPollInterest) SocketPollerProviderError!SocketPollerRegistration {
        try self.requireActive();
        try validateInterest(interest);
        try validateTarget(target);
        for (self.slots[0..self.config.maximum_registrations], 0..) |*slot, index| {
            if (slot.target != null) continue;
            slot.target = target;
            slot.interest = interest;
            return .{ .provider_id = self.provider_id, .slot = @intCast(index), .generation = slot.generation };
        }
        return error.RegistrationCapacityExceeded;
    }

    pub fn updateInterest(self: *SocketPollerProvider, registration: SocketPollerRegistration, interest: transport.SocketPollInterest) SocketPollerProviderError!void {
        try self.requireActive();
        try validateInterest(interest);
        (try self.lookup(registration)).interest = interest;
    }

    pub fn unregister(self: *SocketPollerProvider, registration: SocketPollerRegistration) SocketPollerProviderError!void {
        try self.requireActive();
        const slot = try self.lookup(registration);
        slot.target = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.discardEvents(registration);
    }

    pub fn drain(self: *SocketPollerProvider, output: []SocketPollerProviderEvent) SocketPollerProviderError!usize {
        try self.requireActive();
        const count = @min(output.len, self.event_count);
        for (0..count) |index| output[index] = self.events[(self.event_start + index) % self.config.maximum_events];
        self.event_start = (self.event_start + count) % self.config.maximum_events;
        self.event_count -= count;
        return count;
    }

    pub fn queuedEventCount(self: *const SocketPollerProvider) usize {
        return self.event_count;
    }

    fn poll(self: *SocketPollerProvider, work_budget: usize) SocketPollerProviderError!usize {
        if (self.event_count == self.config.maximum_events) return 0;
        var registrations: [max_socket_poller_provider_registrations]transport.SocketPollRegistration = undefined;
        var handles: [max_socket_poller_provider_registrations]SocketPollerRegistration = undefined;
        var count: usize = 0;
        for (self.slots[0..self.config.maximum_registrations], 0..) |slot, index| {
            const target = slot.target orelse continue;
            registrations[count] = .{ .target = target, .interest = slot.interest };
            handles[count] = .{ .provider_id = self.provider_id, .slot = @intCast(index), .generation = slot.generation };
            count += 1;
        }
        if (count == 0) return 0;
        const poller = if (self.poller) |*value| value else return error.Inactive;
        _ = try poller.wait(registrations[0..count], 0);
        const available = self.config.maximum_events - self.event_count;
        const delivery_budget = @min(work_budget, available);
        var delivered: usize = 0;
        for (registrations[0..count], 0..) |registration, index| {
            if (delivered == delivery_budget) break;
            if (!isReady(registration.event)) continue;
            self.queueEvent(.{ .registration = handles[index], .event = registration.event });
            delivered += 1;
        }
        return delivered;
    }

    fn queueEvent(self: *SocketPollerProvider, value: struct { registration: SocketPollerRegistration, event: transport.SocketPollEvent }) void {
        const index = (self.event_start + self.event_count) % self.config.maximum_events;
        self.events[index] = .{ .sequence = self.next_event_sequence, .registration = value.registration, .event = value.event };
        self.next_event_sequence +%= 1;
        self.event_count += 1;
    }

    fn discardEvents(self: *SocketPollerProvider, registration: SocketPollerRegistration) void {
        var retained: [max_socket_poller_provider_registrations]SocketPollerProviderEvent = undefined;
        var retained_count: usize = 0;
        for (0..self.event_count) |index| {
            const value = self.events[(self.event_start + index) % self.config.maximum_events];
            if (value.registration.provider_id == registration.provider_id and value.registration.slot == registration.slot and value.registration.generation == registration.generation) continue;
            retained[retained_count] = value;
            retained_count += 1;
        }
        for (retained[0..retained_count], 0..) |value, index| self.events[index] = value;
        self.event_start = 0;
        self.event_count = retained_count;
    }

    fn lookup(self: *SocketPollerProvider, registration: SocketPollerRegistration) SocketPollerProviderError!*Slot {
        if (registration.provider_id != self.provider_id or registration.slot >= self.config.maximum_registrations) return error.StaleRegistration;
        const slot = &self.slots[registration.slot];
        if (slot.generation != registration.generation or slot.target == null) return error.StaleRegistration;
        return slot;
    }

    fn requireActive(self: *const SocketPollerProvider) SocketPollerProviderError!void {
        if (!self.active) return error.Inactive;
    }

    fn stop(self: *SocketPollerProvider) void {
        if (self.poller) |*poller| poller.close();
        self.poller = null;
        self.event_start = 0;
        self.event_count = 0;
        self.active = false;
    }

    fn providerInit(context: ?*anyopaque) callconv(.c) c_int {
        const self: *SocketPollerProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (self.active) return @intFromEnum(core.CResult.invalid_state);
        self.poller = transport.SocketPoller.init() catch return @intFromEnum(core.CResult.transport_failure);
        self.active = true;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *provider.ProviderCapabilityDescriptor) callconv(.c) c_int {
        _ = context;
        out_capabilities.* = .{
            .transport_bits = core.transport_capability_bit(.udp) | core.transport_capability_bit(.tcp),
            .delivery_bits = core.delivery_capability_bit(.datagrams) | core.delivery_capability_bit(.streams),
        };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerPoll(context: ?*anyopaque, now: core.TimeNs, work_budget: usize, out_result: *provider.ProviderPollOutput) callconv(.c) c_int {
        const self: *SocketPollerProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        _ = now;
        out_result.* = .{ .work_completed = self.poll(work_budget) catch return @intFromEnum(core.CResult.transport_failure) };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerTeardown(context: ?*anyopaque) callconv(.c) void {
        const self: *SocketPollerProvider = @ptrCast(@alignCast(context orelse return));
        self.stop();
    }
};

fn validateInterest(interest: transport.SocketPollInterest) SocketPollerProviderError!void {
    if (!interest.readable and !interest.writable) return error.InvalidInterest;
}

fn validateTarget(target: transport.SocketPollTarget) SocketPollerProviderError!void {
    switch (target) {
        .udp => {},
        .tcp => |connection| if (connection.socket == null) return error.InvalidTarget,
        .tcp_listener => |listener| if (listener.socket == null) return error.InvalidTarget,
    }
}

fn isReady(event: transport.SocketPollEvent) bool {
    return event.readable or event.writable or event.failure.socket_error or event.failure.socket_hangup or event.failure.invalid_socket;
}

fn localUdpAddress(socket: *transport.UdpSocket) !transport.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &length);
    return transport.Ipv4Address.parse("127.0.0.1", (try transport.Ipv4Address.from_native(native)).port);
}

fn waitForReadable(handle: std.posix.socket_t) !void {
    var descriptors = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try std.posix.poll(&descriptors, 0) != 0) return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

test "socket poller providers deliver mixed readiness through deterministic runtime provider work" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var manual = core.ManualClock.init(0);
        const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .poll_work_budget = 2 } }).build();
        var runtime = try @import("platform_runtime.zig").Runtime.init(allocator, sdk);
        var socket_provider = try SocketPollerProvider.init(.{ .maximum_registrations = 2, .maximum_events = 2, .poll_work_budget = 2 });
        defer {
            runtime.deinit();
            socket_provider.deinit();
        }
        try runtime.registerProvider(try socket_provider.asProvider());
        try runtime.start();
        var udp = try transport.UdpSocket.init(.{});
        defer udp.close();
        try udp.bind(transport.Ipv4Address.wildcard(0));
        const udp_registration = try socket_provider.register(.{ .udp = &udp }, .{});
        var listener = try transport.TcpListener.init(transport.Ipv4Address.wildcard(0), 1);
        defer listener.shutdown();
        const listener_registration = try socket_provider.register(.{ .tcp_listener = &listener }, .{});
        var client = try transport.TcpConnection.init();
        defer if (client.state != .closed) client.close();
        _ = try client.start_connect(try transport.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port), 1_000);
        try waitForReadable(listener.socket.?.handle);
        var sender = try transport.UdpSocket.init(.{});
        defer sender.close();
        _ = try sender.send_to("ready", try localUdpAddress(&udp));
        try waitForReadable(udp.socket.handle);
        var outcome = try runtime.poll(.{ .now_ns = manual.clock().now(), .work_budget = 2 });
        defer outcome.deinit();
        try std.testing.expectEqual(@import("poll_runtime.zig").PollProgress.provider, outcome.progress);
        try std.testing.expectEqual(@as(usize, 2), outcome.provider_work_completed);
        var events: [2]SocketPollerProviderEvent = undefined;
        try std.testing.expectEqual(@as(usize, 2), try socket_provider.drain(events[0..]));
        try std.testing.expectEqual(udp_registration, events[0].registration);
        try std.testing.expect(events[0].event.readable);
        try std.testing.expectEqual(listener_registration, events[1].registration);
        try std.testing.expect(events[1].event.readable);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "socket poller providers validate interest updates and stale registrations" {
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1 } }).build();
    var runtime = try @import("platform_runtime.zig").Runtime.init(std.testing.allocator, sdk);
    var socket_provider = try SocketPollerProvider.init(.{ .maximum_registrations = 1, .maximum_events = 1 });
    defer {
        runtime.deinit();
        socket_provider.deinit();
    }
    try runtime.registerProvider(try socket_provider.asProvider());
    try runtime.start();
    var udp = try transport.UdpSocket.init(.{});
    defer udp.close();
    const registration = try socket_provider.register(.{ .udp = &udp }, .{});
    try socket_provider.updateInterest(registration, .{ .readable = false, .writable = true });
    try std.testing.expectError(error.InvalidInterest, socket_provider.updateInterest(registration, .{ .readable = false, .writable = false }));
    try socket_provider.unregister(registration);
    try std.testing.expectError(error.StaleRegistration, socket_provider.updateInterest(registration, .{}));
}
