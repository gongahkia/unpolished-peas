const std = @import("std");
const core = @import("minna-san-core");
const provider = @import("provider.zig");

pub const max_msquic_provider_events: usize = core.max_event_capacity;

pub const MsQuicCallbackKind = enum(u32) {
    registration_opened = 1,
    listener_started = 2,
    listener_stopped = 3,
    connection_connected = 4,
    connection_shutdown_started = 5,
    connection_shutdown_complete = 6,
    stream_started = 7,
    stream_shutdown_complete = 8,
};

pub const MsQuicCallbackEvent = extern struct {
    kind: u32,
    status: c_int = 0,
    object_id: u64 = 0,

    pub fn callbackKind(self: MsQuicCallbackEvent) ?MsQuicCallbackKind {
        return std.meta.intToEnum(MsQuicCallbackKind, self.kind) catch null;
    }
};

pub const MsQuicRuntimeEvent = struct {
    sequence: u64,
    callback: MsQuicCallbackEvent,
};

pub const MsQuicCallback = *const fn (?*anyopaque, *const MsQuicCallbackEvent) callconv(.c) c_int;

pub const MsQuicProviderVTable = extern struct {
    open: *const fn (?*anyopaque, ?*anyopaque, MsQuicCallback) callconv(.c) c_int,
    close: *const fn (?*anyopaque) callconv(.c) void,
};

pub const msquic_capabilities = provider.ProviderCapabilityDescriptor{
    .transport_bits = core.transport_capability_bit(.quic),
    .security_bits = core.security_capability_bit(.tls),
    .cipher_bits = core.cipher_capability_bit(.aes_256_gcm) | core.cipher_capability_bit(.chacha20_poly1305),
    .delivery_bits = core.delivery_capability_bit(.streams) | core.delivery_capability_bit(.datagrams),
};

pub const msquic_required_capabilities = provider.ProviderCapabilityRequirement{
    .transport_bits = core.transport_capability_bit(.quic),
    .security_bits = core.security_capability_bit(.tls),
    .cipher_bits = core.cipher_capability_bit(.aes_256_gcm) | core.cipher_capability_bit(.chacha20_poly1305),
    .delivery_bits = core.delivery_capability_bit(.streams) | core.delivery_capability_bit(.datagrams),
};

pub const MsQuicProviderConfig = struct {
    maximum_events: usize = 64,
    poll_work_budget: usize = 1,

    pub fn validate(self: MsQuicProviderConfig) error{InvalidConfiguration}!void {
        if (self.maximum_events == 0 or self.maximum_events > max_msquic_provider_events or self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};

pub const MsQuicProviderError = std.mem.Allocator.Error || provider.ProviderError || error{InvalidConfiguration};

const State = enum {
    idle,
    opening,
    active,
    closing,
    closed,
    failed,
};

pub const MsQuicProvider = struct {
    allocator: std.mem.Allocator,
    config: MsQuicProviderConfig,
    context: ?*anyopaque,
    vtable: MsQuicProviderVTable,
    mutex: std.Thread.Mutex = .{},
    pending_events: []MsQuicRuntimeEvent,
    pending_start: usize = 0,
    pending_count: usize = 0,
    runtime_events: []MsQuicRuntimeEvent,
    runtime_start: usize = 0,
    runtime_count: usize = 0,
    next_sequence: u64 = 0,
    state: State = .idle,

    pub fn init(allocator: std.mem.Allocator, config: MsQuicProviderConfig, context: ?*anyopaque, vtable: MsQuicProviderVTable) MsQuicProviderError!MsQuicProvider {
        try config.validate();
        const pending_events = try allocator.alloc(MsQuicRuntimeEvent, config.maximum_events);
        errdefer allocator.free(pending_events);
        const runtime_events = try allocator.alloc(MsQuicRuntimeEvent, config.maximum_events);
        return .{
            .allocator = allocator,
            .config = config,
            .context = context,
            .vtable = vtable,
            .pending_events = pending_events,
            .runtime_events = runtime_events,
        };
    }

    pub fn deinit(self: *MsQuicProvider) void {
        self.stop();
        self.allocator.free(self.pending_events);
        self.allocator.free(self.runtime_events);
        self.* = undefined;
    }

    pub fn asProvider(self: *MsQuicProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = "msquic", .required_capabilities = msquic_required_capabilities, .poll_work_budget = self.config.poll_work_budget }, self, .{ .init = providerInit, .query_capabilities = queryCapabilities, .poll = providerPoll, .teardown = providerTeardown });
    }

    pub fn nextRuntimeEvent(self: *MsQuicProvider) ?MsQuicRuntimeEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.runtime_count == 0) return null;
        const value = self.runtime_events[self.runtime_start];
        self.runtime_start = (self.runtime_start + 1) % self.config.maximum_events;
        self.runtime_count -= 1;
        return value;
    }

    pub fn queuedCallbackCount(self: *MsQuicProvider) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending_count;
    }

    pub fn queuedRuntimeEventCount(self: *MsQuicProvider) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.runtime_count;
    }

    fn providerInit(context: ?*anyopaque) callconv(.c) c_int {
        const self: *MsQuicProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        self.mutex.lock();
        if (self.state != .idle) {
            self.mutex.unlock();
            return @intFromEnum(core.CResult.invalid_state);
        }
        self.state = .opening;
        self.mutex.unlock();
        const result = self.vtable.open(self.context, self, callback);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (result != @intFromEnum(core.CResult.ok)) {
            self.clearQueues();
            self.state = .failed;
            return result;
        }
        self.state = .active;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *provider.ProviderCapabilityDescriptor) callconv(.c) c_int {
        _ = context orelse return @intFromEnum(core.CResult.invalid_argument);
        out_capabilities.* = msquic_capabilities;
        return @intFromEnum(core.CResult.ok);
    }

    fn providerPoll(context: ?*anyopaque, now: core.TimeNs, work_budget: usize, out_result: *provider.ProviderPollOutput) callconv(.c) c_int {
        const self: *MsQuicProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        _ = now;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .active) return @intFromEnum(core.CResult.invalid_state);
        out_result.* = .{ .work_completed = self.movePendingToRuntime(work_budget) };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerTeardown(context: ?*anyopaque) callconv(.c) void {
        const self: *MsQuicProvider = @ptrCast(@alignCast(context orelse return));
        self.stop();
    }

    fn callback(context: ?*anyopaque, event: *const MsQuicCallbackEvent) callconv(.c) c_int {
        const self: *MsQuicProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (self.state) {
            .opening, .active, .closing => {},
            else => return @intFromEnum(core.CResult.invalid_state),
        }
        if (self.pending_count == self.config.maximum_events) return @intFromEnum(core.CResult.resource_exhausted);
        const index = (self.pending_start + self.pending_count) % self.config.maximum_events;
        self.pending_events[index] = .{ .sequence = self.next_sequence, .callback = event.* };
        self.next_sequence +%= 1;
        self.pending_count += 1;
        return @intFromEnum(core.CResult.ok);
    }

    fn stop(self: *MsQuicProvider) void {
        self.mutex.lock();
        if (self.state != .active) {
            self.mutex.unlock();
            return;
        }
        self.state = .closing;
        self.mutex.unlock();
        self.vtable.close(self.context);
        self.mutex.lock();
        _ = self.movePendingToRuntime(self.config.maximum_events);
        self.state = .closed;
        self.mutex.unlock();
    }

    fn movePendingToRuntime(self: *MsQuicProvider, work_budget: usize) usize {
        var work_completed: usize = 0;
        while (work_completed < work_budget and self.pending_count != 0 and self.runtime_count < self.config.maximum_events) : (work_completed += 1) {
            const pending = self.pending_events[self.pending_start];
            self.pending_start = (self.pending_start + 1) % self.config.maximum_events;
            self.pending_count -= 1;
            const output_index = (self.runtime_start + self.runtime_count) % self.config.maximum_events;
            self.runtime_events[output_index] = pending;
            self.runtime_count += 1;
        }
        return work_completed;
    }

    fn clearQueues(self: *MsQuicProvider) void {
        self.pending_start = 0;
        self.pending_count = 0;
        self.runtime_start = 0;
        self.runtime_count = 0;
    }
};

test "MsQuic adapters deliver fake callback traces only through explicit runtime polls" {
    const FakeMsQuic = struct {
        opens: usize = 0,
        closes: usize = 0,
        callback_context: ?*anyopaque = null,
        callback_fn: ?MsQuicCallback = null,

        fn open(context: ?*anyopaque, callback_context: ?*anyopaque, callback_fn: MsQuicCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.opens += 1;
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            const trace = [_]MsQuicCallbackEvent{
                .{ .kind = @intFromEnum(MsQuicCallbackKind.registration_opened), .object_id = 10 },
                .{ .kind = @intFromEnum(MsQuicCallbackKind.connection_connected), .object_id = 11 },
                .{ .kind = @intFromEnum(MsQuicCallbackKind.connection_shutdown_complete), .object_id = 11 },
            };
            for (trace) |entry| if (callback_fn(callback_context, &entry) != @intFromEnum(core.CResult.ok)) return @intFromEnum(core.CResult.resource_exhausted);
            return @intFromEnum(core.CResult.ok);
        }

        fn close(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closes += 1;
            const stopped = MsQuicCallbackEvent{ .kind = @intFromEnum(MsQuicCallbackKind.listener_stopped), .object_id = 10 };
            _ = self.callback_fn.?(self.callback_context, &stopped);
        }
    };

    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .poll_work_budget = 2 } }).build();
    var fake = FakeMsQuic{};
    var adapter = try MsQuicProvider.init(std.testing.allocator, .{ .maximum_events = 3, .poll_work_budget = 2 }, &fake, .{ .open = FakeMsQuic.open, .close = FakeMsQuic.close });
    defer adapter.deinit();
    var runtime = try @import("platform_runtime.zig").Runtime.init(std.testing.allocator, sdk);
    defer runtime.deinit();
    try runtime.registerProvider(try adapter.asProvider());
    try runtime.start();
    try std.testing.expectEqual(@as(usize, 1), fake.opens);
    try std.testing.expectEqual(@as(usize, 3), adapter.queuedCallbackCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.queuedRuntimeEventCount());
    try std.testing.expect(runtime.providers.providers[0].capabilities.supports(msquic_required_capabilities));

    var first = try runtime.poll(.{ .now_ns = manual.clock().now(), .work_budget = 2 });
    defer first.deinit();
    try std.testing.expectEqual(@import("poll_runtime.zig").PollProgress.provider, first.progress);
    try std.testing.expectEqual(@as(usize, 2), first.provider_work_completed);
    try std.testing.expectEqual(@as(usize, 1), adapter.queuedCallbackCount());
    const opened = adapter.nextRuntimeEvent().?;
    try std.testing.expectEqual(@as(u64, 0), opened.sequence);
    try std.testing.expectEqual(MsQuicCallbackKind.registration_opened, opened.callback.callbackKind().?);
    try std.testing.expectEqual(@as(u64, 10), opened.callback.object_id);
    const connected = adapter.nextRuntimeEvent().?;
    try std.testing.expectEqual(@as(u64, 1), connected.sequence);
    try std.testing.expectEqual(MsQuicCallbackKind.connection_connected, connected.callback.callbackKind().?);

    var second = try runtime.poll(.{ .now_ns = manual.clock().now(), .work_budget = 2 });
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.provider_work_completed);
    const shutdown_complete = adapter.nextRuntimeEvent().?;
    try std.testing.expectEqual(@as(u64, 2), shutdown_complete.sequence);
    try std.testing.expectEqual(MsQuicCallbackKind.connection_shutdown_complete, shutdown_complete.callback.callbackKind().?);
    try std.testing.expect(adapter.nextRuntimeEvent() == null);
    runtime.providers.providers[0].stop();
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
    const stopped = adapter.nextRuntimeEvent().?;
    try std.testing.expectEqual(@as(u64, 3), stopped.sequence);
    try std.testing.expectEqual(MsQuicCallbackKind.listener_stopped, stopped.callback.callbackKind().?);
}

test "MsQuic adapters report bounded callback queues to native bridges" {
    const FakeMsQuic = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?MsQuicCallback = null,

        fn open(context: ?*anyopaque, callback_context: ?*anyopaque, callback_fn: MsQuicCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            return @intFromEnum(core.CResult.ok);
        }

        fn close(_: ?*anyopaque) callconv(.c) void {}

        fn emit(self: *@This(), event: MsQuicCallbackEvent) c_int {
            return self.callback_fn.?(self.callback_context, &event);
        }
    };

    var fake = FakeMsQuic{};
    var adapter = try MsQuicProvider.init(std.testing.allocator, .{ .maximum_events = 1 }, &fake, .{ .open = FakeMsQuic.open, .close = FakeMsQuic.close });
    defer adapter.deinit();
    var registered = try adapter.asProvider();
    try registered.start();
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), fake.emit(.{ .kind = @intFromEnum(MsQuicCallbackKind.connection_connected) }));
    try std.testing.expectEqual(@intFromEnum(core.CResult.resource_exhausted), fake.emit(.{ .kind = @intFromEnum(MsQuicCallbackKind.connection_shutdown_complete) }));
    try std.testing.expectEqual(@as(usize, 1), (try registered.poll(0)).work_completed);
    try std.testing.expectEqual(@as(u64, 0), adapter.nextRuntimeEvent().?.sequence);
    registered.stop();
}
