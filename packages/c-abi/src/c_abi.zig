const core = @import("minna-san-core");
const runtime = @import("minna-san-runtime");
const std = @import("std");

pub const CAbiVersion = u32;
pub const CAbiHandle = opaque {};
pub const CVersion = extern struct {
    major: u16,
    minor: u16,
    patch: u16,
};
pub const CDurationNs = i64;
pub const CAddressFamily = enum(u8) {
    unspecified = 0,
    ipv4 = 4,
    ipv6 = 6,
};
pub const CAddress = extern struct {
    family: u8,
    bytes: [16]u8,
    port: u16,
};
pub const CBuffer = extern struct {
    data: [*c]u8,
    len: usize,
};
pub const CAllocateFn = *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque;
pub const CReleaseFn = *const fn (?*anyopaque, [*c]u8, usize) callconv(.c) void;
pub const CAllocator = extern struct {
    context: ?*anyopaque,
    allocate: ?CAllocateFn,
    release: ?CReleaseFn,
};
pub const CAllocatorError = error{ MissingAllocateCallback, AllocationFailed };
pub const CBufferReleaseError = error{ MissingReleaseCallback, InvalidBuffer };
pub const CResult = core.CResult;
pub const CErrorCategory = core.ErrorClass;
pub const CEventKind = enum(u32) {
    connected = 1,
    disconnected = 2,
    message = 3,
    overflow = 4,
};
pub const CEvent = extern struct {
    kind: u32,
    mode: u32,
    sequence: u64,
    payload: CBuffer,
};
pub const CNowFn = *const fn (?*anyopaque) callconv(.c) core.TimeNs;
pub const CSdk = opaque {};
pub const CSdkConfig = extern struct {
    abi_version: CAbiVersion,
    capability_bits: u32,
    clock_context: ?*anyopaque,
    now: ?CNowFn,
    allocator: CAllocator,
};
pub const c_capability_transport: u32 = 1 << @intFromEnum(core.Capability.transport);
pub const c_capability_packet_protection: u32 = 1 << @intFromEnum(core.Capability.packet_protection);
pub const c_capability_topology: u32 = 1 << @intFromEnum(core.Capability.topology);
pub const c_capability_state_replication: u32 = 1 << @intFromEnum(core.Capability.state_replication);
pub const c_capability_capture: u32 = 1 << @intFromEnum(core.Capability.capture);
const all_capability_bits = c_capability_transport | c_capability_packet_protection | c_capability_topology | c_capability_state_replication | c_capability_capture;
pub const c_abi_version: CAbiVersion = runtime.abi_version();

const CClockBridge = struct {
    context: ?*anyopaque,
    now: CNowFn,

    fn clock(self: *CClockBridge) core.Clock {
        return .{ .context = self, .now_fn = now_bridge };
    }

    fn now_bridge(context: *anyopaque) core.TimeNs {
        const self: *CClockBridge = @ptrCast(@alignCast(context));
        return self.now(self.context);
    }
};

const CAllocatorBridge = struct {
    c_allocator: CAllocator,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    };

    fn allocator(self: *CAllocatorBridge) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *CAllocatorBridge = @ptrCast(@alignCast(context));
        if (len == 0) return @ptrFromInt(alignment.toByteUnits());
        const buffer = allocate_buffer(self.c_allocator, len) catch return null;
        const data: [*]u8 = @ptrCast(buffer.data);
        if (@intFromPtr(data) % alignment.toByteUnits() == 0) return data;
        release_buffer(self.c_allocator, buffer) catch {};
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *CAllocatorBridge = @ptrCast(@alignCast(context));
        release_buffer(self.c_allocator, .{ .data = @ptrCast(memory.ptr), .len = memory.len }) catch {};
    }
};

const CSdkState = struct {
    allocator_bridge: CAllocatorBridge,
    clock_bridge: CClockBridge,
    sdk: runtime.Sdk,
    poll_runtime: runtime.PollRuntime,
    started: bool,
};

pub fn is_valid_buffer(buffer: CBuffer) bool {
    return buffer.data != null or buffer.len == 0;
}

pub fn allocate_buffer(allocator: CAllocator, len: usize) CAllocatorError!CBuffer {
    if (len == 0) return .{ .data = null, .len = 0 };
    const allocate = allocator.allocate orelse return error.MissingAllocateCallback;
    const data = allocate(allocator.context, len) orelse return error.AllocationFailed;
    return .{ .data = @ptrCast(data), .len = len };
}

pub fn release_buffer(allocator: CAllocator, buffer: CBuffer) CBufferReleaseError!void {
    if (!is_valid_buffer(buffer)) return error.InvalidBuffer;
    if (buffer.len == 0) return;
    const release = allocator.release orelse return error.MissingReleaseCallback;
    release(allocator.context, buffer.data, buffer.len);
}

pub fn result_is_known(result_code: c_int) bool {
    return core.c_result_from_code(result_code) != null;
}

pub fn result_category(result_code: c_int) CErrorCategory {
    const result = core.c_result_from_code(result_code) orelse return .internal;
    return core.class_for_c_result(result);
}

pub fn result_message(result_code: c_int) [*:0]const u8 {
    const result = core.c_result_from_code(result_code) orelse return "unknown result code";
    return switch (result) {
        .ok => "ok",
        .invalid_argument => "invalid argument",
        .invalid_state => "invalid state",
        .unsupported => "unsupported",
        .resource_exhausted => "resource exhausted",
        .timeout => "timeout",
        .cancelled => "cancelled",
        .would_block => "would block",
        .authentication_failed => "authentication failed",
        .permission_denied => "permission denied",
        .protocol_violation => "protocol violation",
        .version_mismatch => "version mismatch",
        .integrity_failed => "integrity failed",
        .transport_failure => "transport failure",
        .internal => "internal",
    };
}

pub fn validate_sdk_config(config: ?*const CSdkConfig) CResult {
    const value = config orelse return .invalid_argument;
    if (value.abi_version != c_abi_version) return .version_mismatch;
    if (value.now == null or value.allocator.allocate == null or value.allocator.release == null) return .invalid_argument;
    if (value.capability_bits & ~all_capability_bits != 0) return .invalid_argument;
    var capabilities = core.CapabilityConfig{};
    inline for (std.meta.fields(core.Capability)) |field| {
        const capability: core.Capability = @enumFromInt(field.value);
        if (value.capability_bits & (@as(u32, 1) << @intCast(field.value)) != 0) capabilities.enable(capability);
    }
    capabilities.validate() catch return .unsupported;
    return .ok;
}

fn config_result_code(config: ?*const CSdkConfig) c_int {
    return @intFromEnum(validate_sdk_config(config));
}

fn state_from_handle(handle: ?*CSdk) ?*CSdkState {
    const value = handle orelse return null;
    return @ptrCast(@alignCast(value));
}

fn build_sdk(config: *const CSdkConfig, clock: core.Clock) runtime.Sdk {
    var builder = runtime.SdkConfigBuilder.init().with_clock(clock);
    inline for (std.meta.fields(core.Capability)) |field| {
        const capability: core.Capability = @enumFromInt(field.value);
        if (config.capability_bits & (@as(u32, 1) << @intCast(field.value)) != 0) builder = builder.enable(capability);
    }
    return builder.build() catch unreachable;
}

pub export fn minna_san_abi_version() CAbiVersion {
    return c_abi_version;
}

pub export fn minna_san_abi_supports_version(requested_version: CAbiVersion) u8 {
    return @intFromBool(requested_version == c_abi_version);
}

pub export fn minna_san_result_is_known(result_code: c_int) u8 {
    return @intFromBool(result_is_known(result_code));
}

pub export fn minna_san_result_category(result_code: c_int) c_int {
    return @intFromEnum(result_category(result_code));
}

pub export fn minna_san_result_message(result_code: c_int) [*:0]const u8 {
    return result_message(result_code);
}

pub export fn minna_san_sdk_validate_config(config: ?*const CSdkConfig) c_int {
    return config_result_code(config);
}

pub export fn minna_san_sdk_create(config: ?*const CSdkConfig, out_sdk: ?*?*CSdk) c_int {
    const output = out_sdk orelse return @intFromEnum(CResult.invalid_argument);
    output.* = null;
    if (validate_sdk_config(config) != .ok) return config_result_code(config);
    const value = config.?;
    var initial_allocator_bridge = CAllocatorBridge{ .c_allocator = value.allocator };
    const initial_allocator = initial_allocator_bridge.allocator();
    const state = initial_allocator.create(CSdkState) catch return @intFromEnum(CResult.resource_exhausted);
    errdefer initial_allocator.destroy(state);
    state.allocator_bridge = .{ .c_allocator = value.allocator };
    state.clock_bridge = .{ .context = value.clock_context, .now = value.now.? };
    state.sdk = build_sdk(value, state.clock_bridge.clock());
    state.poll_runtime = runtime.PollRuntime.init(state.allocator_bridge.allocator(), state.sdk);
    state.started = false;
    output.* = @ptrCast(state);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_sdk_start(sdk: ?*CSdk) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    if (state.started) return @intFromEnum(CResult.invalid_state);
    state.started = true;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_sdk_poll(sdk: ?*CSdk, out_event: ?*CEvent) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    const output = out_event orelse return @intFromEnum(CResult.invalid_argument);
    output.* = .{ .kind = 0, .mode = 0, .sequence = 0, .payload = .{ .data = null, .len = 0 } };
    var envelope = state.poll_runtime.poll() catch return @intFromEnum(CResult.internal);
    if (envelope) |*value| value.deinit();
    return @intFromEnum(CResult.would_block);
}

pub export fn minna_san_sdk_stop(sdk: ?*CSdk) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    state.started = false;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_sdk_destroy(sdk: ?*CSdk) void {
    const state = state_from_handle(sdk) orelse return;
    const allocator = state.allocator_bridge.allocator();
    state.poll_runtime.deinit();
    allocator.destroy(state);
}

pub const package_name = "c_abi";

comptime {
    _ = core.package_name;
    _ = runtime.package_name;
}

test "C ABI package boundary" {
    try std.testing.expectEqualStrings("c_abi", package_name);
}

test "C ABI exports its supported version" {
    try std.testing.expectEqual(runtime.abi_version(), minna_san_abi_version());
    try std.testing.expectEqual(@as(u8, 1), minna_san_abi_supports_version(c_abi_version));
}

test "C ABI rejects unsupported versions without exposing handle layout" {
    const handle: ?*CAbiHandle = null;
    try std.testing.expect(handle == null);
    try std.testing.expectEqual(@as(u8, 0), minna_san_abi_supports_version(c_abi_version + 1));
}

test "C ABI core declarations use C-safe layouts" {
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(CVersion));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(CAddress));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf([16]u8));
    try std.testing.expectEqual(@as(usize, @sizeOf(usize) * 2), @sizeOf(CBuffer));
    try std.testing.expectEqual(@as(usize, 16 + @sizeOf(CBuffer)), @sizeOf(CEvent));
}

test "C ABI buffer declarations reject null nonempty data" {
    try std.testing.expect(is_valid_buffer(.{ .data = null, .len = 0 }));
    try std.testing.expect(!is_valid_buffer(.{ .data = null, .len = 1 }));
}

test "C ABI allocator bridge preserves caller allocation and release" {
    const Callbacks = struct {
        var storage: [8]u8 = undefined;
        var released_len: usize = 0;

        fn allocate(_: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
            if (len > storage.len) return null;
            return @ptrCast(&storage);
        }

        fn release(_: ?*anyopaque, _: [*c]u8, len: usize) callconv(.c) void {
            released_len = len;
        }
    };
    const allocator = CAllocator{ .context = null, .allocate = Callbacks.allocate, .release = Callbacks.release };
    const buffer = try allocate_buffer(allocator, 8);
    try release_buffer(allocator, buffer);
    try std.testing.expectEqual(@as(usize, 8), Callbacks.released_len);
}

test "C ABI allocator bridge rejects missing and failed callbacks" {
    const missing = CAllocator{ .context = null, .allocate = null, .release = null };
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(usize)), @sizeOf(CAllocator));
    try std.testing.expectEqual(@as(usize, 0), (try allocate_buffer(missing, 0)).len);
    try std.testing.expectError(error.MissingAllocateCallback, allocate_buffer(missing, 1));
    try std.testing.expectError(error.MissingReleaseCallback, release_buffer(missing, .{ .data = @ptrFromInt(1), .len = 1 }));
    try std.testing.expectError(error.InvalidBuffer, release_buffer(missing, .{ .data = null, .len = 1 }));
}

test "C ABI result inspection preserves stable categories" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(CResult.ok));
    try std.testing.expectEqual(@as(c_int, 11), @intFromEnum(CResult.version_mismatch));
    try std.testing.expectEqual(@as(c_int, 14), @intFromEnum(CResult.internal));
    try std.testing.expectEqual(@as(u8, 1), minna_san_result_is_known(11));
    try std.testing.expectEqual(@as(c_int, 11), minna_san_result_category(11));
    try std.testing.expectEqualStrings("version mismatch", std.mem.span(minna_san_result_message(11)));
}

test "C ABI result inspection classifies unknown codes without allocation" {
    try std.testing.expectEqual(@as(u8, 0), minna_san_result_is_known(-1));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CErrorCategory.internal)), minna_san_result_category(-1));
    try std.testing.expectEqualStrings("unknown result code", std.mem.span(minna_san_result_message(-1)));
}

test "C SDK lifecycle creates validates starts polls stops and destroys" {
    const Fixture = struct {
        var storage: [@sizeOf(CSdkState)]u8 align(@alignOf(CSdkState)) = undefined;
        var released: bool = false;

        fn allocate(_: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
            if (len != storage.len) return null;
            return @ptrCast(&storage);
        }

        fn release(_: ?*anyopaque, _: [*c]u8, len: usize) callconv(.c) void {
            released = len == storage.len;
        }

        fn now(_: ?*anyopaque) callconv(.c) core.TimeNs {
            return 42;
        }
    };
    Fixture.released = false;
    const config = CSdkConfig{
        .abi_version = c_abi_version,
        .capability_bits = c_capability_transport,
        .clock_context = null,
        .now = Fixture.now,
        .allocator = .{ .context = null, .allocate = Fixture.allocate, .release = Fixture.release },
    };
    var sdk: ?*CSdk = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_validate_config(&config));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_create(&config, &sdk));
    try std.testing.expect(sdk != null);
    var event: CEvent = undefined;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_state)), minna_san_sdk_poll(sdk, &event));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_start(sdk));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_state)), minna_san_sdk_start(sdk));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.would_block)), minna_san_sdk_poll(sdk, &event));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_stop(sdk));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_state)), minna_san_sdk_stop(sdk));
    minna_san_sdk_destroy(sdk);
    try std.testing.expect(Fixture.released);
    var mismatched = config;
    mismatched.abi_version = c_abi_version - 1;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.version_mismatch)), minna_san_sdk_validate_config(&mismatched));
    mismatched.abi_version = c_abi_version;
    mismatched.capability_bits = c_capability_packet_protection;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.unsupported)), minna_san_sdk_validate_config(&mismatched));
}

test "C SDK lifecycle rejects invalid configuration and ordering" {
    var sdk: ?*CSdk = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_create(null, &sdk));
    const invalid = CSdkConfig{
        .abi_version = c_abi_version,
        .capability_bits = c_capability_packet_protection,
        .clock_context = null,
        .now = null,
        .allocator = .{ .context = null, .allocate = null, .release = null },
    };
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_validate_config(&invalid));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_start(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_poll(null, null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_stop(null));
}
