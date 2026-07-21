const std = @import("std");
const core = @import("minna-san-core");
const transport = @import("minna-san-transport");
const provider = @import("provider.zig");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");

pub const max_hostname_resolution_requests: usize = core.max_session_capacity;

pub const HostnameResolutionProviderError = std.mem.Allocator.Error || provider.ProviderError || resource.HandleError || session.SessionRegistryError || transport.EndpointError || error{ InvalidConfiguration, Inactive, RequestCapacityExceeded, StaleRequest, InvalidState, Cancelled, NotReady, ResolutionFailed, SessionExpired, ThreadStartFailed };

pub const HostnameResolutionProviderConfig = struct {
    max_requests: usize = 64,
    poll_work_budget: usize = 1,

    pub fn validate(self: HostnameResolutionProviderConfig) HostnameResolutionProviderError!void {
        if (self.max_requests == 0 or self.max_requests > max_hostname_resolution_requests or self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};

pub const HostnameResolutionRequestHandle = struct {
    provider_id: u32,
    slot: u32,
    generation: u32,
};

pub const HostnameResolutionRequestState = enum { resolving, resolved, failed, cancelled, stale };

pub const HostnameResolutionResult = struct {
    addresses: [transport.max_hostname_addresses]transport.ResolvedAddress = undefined,
    address_count: usize = 0,

    pub fn items(self: *const HostnameResolutionResult) []const transport.ResolvedAddress {
        return self.addresses[0..self.address_count];
    }
};

const Request = struct {
    session: *resource.ResourceHandle,
    resolution: transport.HostnameResolution,
    state: HostnameResolutionRequestState = .resolving,
    result: HostnameResolutionResult = .{},
};

const Slot = struct {
    generation: u32 = 1,
    request: ?*Request = null,
};

var next_provider_id = std.atomic.Value(u32).init(1);

pub const HostnameResolutionProvider = struct {
    allocator: std.mem.Allocator,
    sessions: *session.SessionRegistry,
    config: HostnameResolutionProviderConfig,
    provider_id: u32,
    slots: []Slot,
    next_slot: usize = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, sessions: *session.SessionRegistry, config: HostnameResolutionProviderConfig) HostnameResolutionProviderError!HostnameResolutionProvider {
        try config.validate();
        const provider_id = next_provider_id.fetchAdd(1, .monotonic);
        if (provider_id == 0) return error.InvalidConfiguration;
        const slots = try allocator.alloc(Slot, config.max_requests);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .sessions = sessions, .config = config, .provider_id = provider_id, .slots = slots };
    }

    pub fn deinit(self: *HostnameResolutionProvider) void {
        for (self.slots, 0..) |slot, index| if (slot.request != null) self.destroyRequest(index);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn asProvider(self: *HostnameResolutionProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = "hostname-resolver", .poll_work_budget = self.config.poll_work_budget }, self, .{ .init = providerInit, .query_capabilities = queryCapabilities, .poll = providerPoll, .teardown = providerTeardown });
    }

    pub fn resolve(self: *HostnameResolutionProvider, owner: *resource.ResourceHandle, hostname: []const u8, port: u16) HostnameResolutionProviderError!HostnameResolutionRequestHandle {
        if (!self.active) return error.Inactive;
        _ = self.sessions.lookup(owner) catch return error.SessionExpired;
        const endpoint = try transport.Endpoint.from_hostname(hostname, port);
        const index = self.freeSlot() orelse return error.RequestCapacityExceeded;
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{
            .session = owner,
            .resolution = transport.HostnameResolution.init(self.allocator, endpoint.name[0..endpoint.name_len], endpoint.port) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidConfiguration,
            },
        };
        errdefer request.resolution.deinit();
        request.resolution.start() catch |err| switch (err) {
            error.ThreadStartFailed => return error.ThreadStartFailed,
            else => return error.InvalidState,
        };
        self.slots[index].request = request;
        return .{ .provider_id = self.provider_id, .slot = @intCast(index), .generation = self.slots[index].generation };
    }

    pub fn state(self: *HostnameResolutionProvider, handle: HostnameResolutionRequestHandle) HostnameResolutionProviderError!HostnameResolutionRequestState {
        return (try self.lookupRequest(handle)).state;
    }

    pub fn result(self: *HostnameResolutionProvider, handle: HostnameResolutionRequestHandle) HostnameResolutionProviderError!HostnameResolutionResult {
        const request = try self.lookupRequest(handle);
        switch (request.state) {
            .resolving => {
                _ = self.sessions.lookup(request.session) catch {
                    request.state = .stale;
                    return error.SessionExpired;
                };
                return error.NotReady;
            },
            .resolved => {
                _ = self.sessions.lookup(request.session) catch {
                    request.state = .stale;
                    return error.SessionExpired;
                };
                return request.result;
            },
            .failed => return error.ResolutionFailed,
            .cancelled => return error.Cancelled,
            .stale => return error.SessionExpired,
        }
    }

    pub fn cancel(self: *HostnameResolutionProvider, handle: HostnameResolutionRequestHandle) HostnameResolutionProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state != .resolving) return error.InvalidState;
        request.state = .cancelled;
    }

    pub fn release(self: *HostnameResolutionProvider, handle: HostnameResolutionRequestHandle) HostnameResolutionProviderError!void {
        const request = try self.lookupRequest(handle);
        switch (request.state) {
            .resolved, .failed => self.destroyRequest(handle.slot),
            .resolving => return error.NotReady,
            .cancelled => return error.Cancelled,
            .stale => return error.SessionExpired,
        }
    }

    fn poll(self: *HostnameResolutionProvider, work_budget: usize) usize {
        var work_completed: usize = 0;
        var inspected: usize = 0;
        while (inspected < work_budget) : (inspected += 1) {
            const index = self.next_slot;
            self.next_slot = (self.next_slot + 1) % self.slots.len;
            const request = self.slots[index].request orelse continue;
            const status = request.resolution.status();
            switch (request.state) {
                .resolving => {
                    if (self.sessions.lookup(request.session)) |_| {
                        switch (status) {
                            .resolved => {
                                const addresses = request.resolution.result() catch {
                                    request.state = .failed;
                                    work_completed += 1;
                                    continue;
                                };
                                @memcpy(request.result.addresses[0..addresses.len], addresses);
                                request.result.address_count = addresses.len;
                                request.state = .resolved;
                                work_completed += 1;
                            },
                            .failed => {
                                request.state = .failed;
                                work_completed += 1;
                            },
                            .pending, .resolving => {},
                        }
                    } else |_| {
                        request.state = .stale;
                        if (status == .resolved or status == .failed) {
                            self.destroyRequest(index);
                            work_completed += 1;
                        }
                    }
                },
                .cancelled, .stale => if (status == .resolved or status == .failed) {
                    self.destroyRequest(index);
                    work_completed += 1;
                },
                .resolved, .failed => {},
            }
        }
        return work_completed;
    }

    fn lookupRequest(self: *HostnameResolutionProvider, handle: HostnameResolutionRequestHandle) HostnameResolutionProviderError!*Request {
        if (handle.provider_id != self.provider_id or handle.slot >= self.slots.len) return error.StaleRequest;
        const slot = &self.slots[handle.slot];
        if (slot.generation != handle.generation) return error.StaleRequest;
        return slot.request orelse error.StaleRequest;
    }

    fn freeSlot(self: *HostnameResolutionProvider) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.request == null) return index;
        return null;
    }

    fn destroyRequest(self: *HostnameResolutionProvider, index: usize) void {
        const slot = &self.slots[index];
        const request = slot.request orelse return;
        request.resolution.deinit();
        self.allocator.destroy(request);
        slot.request = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    fn providerInit(context: ?*anyopaque) callconv(.c) c_int {
        const self: *HostnameResolutionProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (self.active) return @intFromEnum(core.CResult.invalid_state);
        self.active = true;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *provider.ProviderCapabilityDescriptor) callconv(.c) c_int {
        _ = context;
        out_capabilities.* = .{};
        return @intFromEnum(core.CResult.ok);
    }

    fn providerPoll(context: ?*anyopaque, now: core.TimeNs, work_budget: usize, out_result: *provider.ProviderPollOutput) callconv(.c) c_int {
        const self: *HostnameResolutionProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        _ = now;
        if (!self.active) return @intFromEnum(core.CResult.invalid_state);
        out_result.* = .{ .work_completed = self.poll(work_budget) };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerTeardown(context: ?*anyopaque) callconv(.c) void {
        const self: *HostnameResolutionProvider = @ptrCast(@alignCast(context orelse return));
        self.active = false;
        for (self.slots) |slot| {
            const request = slot.request orelse continue;
            if (request.state == .resolving) request.state = .cancelled;
        }
    }
};

test "hostname resolution providers expose bounded pollable results" {
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .session_capacity = 1, .channel_capacity = 1, .poll_work_budget = 1 } }).build();
    var runtime = try @import("platform_runtime.zig").Runtime.init(std.testing.allocator, sdk);
    var resolver = try HostnameResolutionProvider.init(std.testing.allocator, runtime.sessions, .{ .max_requests = 1, .poll_work_budget = 1 });
    defer {
        runtime.deinit();
        resolver.deinit();
    }
    try runtime.registerProvider(try resolver.asProvider());
    try runtime.start();
    const owner = try runtime.createSession();
    try runtime.transitionSession(owner, .begin_establishing);
    const request = try resolver.resolve(owner, "LOCALHOST.", 9000);
    var attempts: usize = 0;
    while (attempts < 1_000) : (attempts += 1) {
        var outcome = try runtime.poll(.{ .now_ns = manual.clock().now(), .work_budget = 1 });
        outcome.deinit();
        if (resolver.result(request)) |result| {
            try std.testing.expect(result.items().len > 0);
            try std.testing.expect(result.items().len <= transport.max_hostname_addresses);
            break;
        } else |err| switch (err) {
            error.NotReady => std.Thread.sleep(std.time.ns_per_ms),
            else => return err,
        }
    }
    try std.testing.expect(attempts < 1_000);
    try std.testing.expectEqual(session.SessionState.establishing, (try runtime.session(owner)).state);
    try resolver.release(request);
}

test "cancelled and stale hostname results never mutate sessions" {
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .session_capacity = 1, .channel_capacity = 1, .poll_work_budget = 1 } }).build();
    var runtime = try @import("platform_runtime.zig").Runtime.init(std.testing.allocator, sdk);
    var resolver = try HostnameResolutionProvider.init(std.testing.allocator, runtime.sessions, .{ .max_requests = 1, .poll_work_budget = 1 });
    defer {
        runtime.deinit();
        resolver.deinit();
    }
    try runtime.registerProvider(try resolver.asProvider());
    try runtime.start();
    const owner = try runtime.createSession();
    try runtime.transitionSession(owner, .begin_establishing);
    const cancelled = try resolver.resolve(owner, "localhost", 9000);
    try resolver.cancel(cancelled);
    try std.testing.expectError(error.Cancelled, resolver.result(cancelled));
    try std.testing.expectEqual(session.SessionState.establishing, (try runtime.session(owner)).state);
    try runtime.transitionSession(owner, .begin_draining);
    try runtime.closeSession(owner);
    var attempts: usize = 0;
    while (attempts < 1_000) : (attempts += 1) {
        var outcome = try runtime.poll(.{ .now_ns = manual.clock().now(), .work_budget = 1 });
        outcome.deinit();
        if (resolver.state(cancelled)) |_| {
            std.Thread.sleep(std.time.ns_per_ms);
        } else |err| switch (err) {
            error.StaleRequest => break,
            else => return err,
        }
    }
    try std.testing.expect(attempts < 1_000);
    try std.testing.expectError(error.StaleHandle, runtime.session(owner));
    const stale_owner = try runtime.createSession();
    try runtime.transitionSession(stale_owner, .begin_establishing);
    const stale = try resolver.resolve(stale_owner, "localhost", 9000);
    try runtime.transitionSession(stale_owner, .begin_draining);
    try runtime.closeSession(stale_owner);
    try std.testing.expectError(error.SessionExpired, resolver.result(stale));
}
