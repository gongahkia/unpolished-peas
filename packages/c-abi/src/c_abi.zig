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
pub const CConnection = opaque {};
pub const CPeer = opaque {};
pub const CChannel = opaque {};
pub const CAuthoritativeSession = opaque {};
pub const CSdkConfig = extern struct {
    abi_version: CAbiVersion,
    capability_bits: u32,
    connection_capacity: usize,
    channel_capacity: usize,
    clock_context: ?*anyopaque,
    now: ?CNowFn,
    allocator: CAllocator,
};
pub const CRouteState = enum(u32) {
    direct = 1,
    relay = 2,
};
pub const CChannelMode = enum(u32) {
    reliable = 1,
    sequenced = 2,
};
pub const CAdmissionDecision = enum(u32) {
    accept = 1,
    reject = 2,
};
pub const CAdmissionFn = *const fn (?*anyopaque, *const CPeer) callconv(.c) u32;
pub const CAuthoritativeSessionConfig = extern struct {
    max_clients: usize,
    admission_context: ?*anyopaque,
    admission: ?CAdmissionFn,
};
pub const CTransportKind = enum(u32) {
    udp = 1,
    tcp = 2,
};
pub const CSocketOptions = extern struct {
    send_buffer_bytes: u32,
    receive_buffer_bytes: u32,
    reuse_address: u8,
    no_delay: u8,
    reserved: [2]u8,
};
pub const CTransportControl = extern struct {
    connect_timeout_ns: CDurationNs,
    idle_timeout_ns: CDurationNs,
    max_datagram_bytes: u32,
    max_in_flight: u32,
};
pub const CTransportConfig = extern struct {
    kind: u32,
    local_address: CAddress,
    remote_address: CAddress,
    socket_options: CSocketOptions,
    control: CTransportControl,
};
pub const CSecurityConfig = extern struct {
    flags: u32,
    psk: CBuffer,
    public_key: CBuffer,
    aead_key: CBuffer,
    replay_window: u32,
    rotation_interval_ns: CDurationNs,
    rotation_overlap_ns: CDurationNs,
};
pub const c_capability_transport: u32 = 1 << @intFromEnum(core.Capability.transport);
pub const c_capability_packet_protection: u32 = 1 << @intFromEnum(core.Capability.packet_protection);
pub const c_capability_topology: u32 = 1 << @intFromEnum(core.Capability.topology);
pub const c_capability_state_replication: u32 = 1 << @intFromEnum(core.Capability.state_replication);
pub const c_capability_capture: u32 = 1 << @intFromEnum(core.Capability.capture);
pub const c_transport_udp: u32 = @intFromEnum(CTransportKind.udp);
pub const c_transport_tcp: u32 = @intFromEnum(CTransportKind.tcp);
pub const c_route_direct: u32 = @intFromEnum(CRouteState.direct);
pub const c_route_relay: u32 = @intFromEnum(CRouteState.relay);
pub const c_channel_reliable: u32 = @intFromEnum(CChannelMode.reliable);
pub const c_channel_sequenced: u32 = @intFromEnum(CChannelMode.sequenced);
pub const c_security_psk: u32 = 1;
pub const c_security_public_key: u32 = 2;
pub const c_security_aead: u32 = 4;
pub const c_security_replay_protection: u32 = 8;
pub const c_security_key_rotation: u32 = 16;
pub const c_admission_accept: u32 = @intFromEnum(CAdmissionDecision.accept);
pub const c_admission_reject: u32 = @intFromEnum(CAdmissionDecision.reject);
const all_security_flags = c_security_psk | c_security_public_key | c_security_aead | c_security_replay_protection | c_security_key_rotation;
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
    connections: runtime.ResourceRegistry,
    peers: runtime.ResourceRegistry,
    connection_records: std.ArrayListUnmanaged(ConnectionRecord),
    channels: runtime.ResourceRegistry,
    channel_records: std.ArrayListUnmanaged(ChannelRecord),
    sessions: runtime.ResourceRegistry,
    session_records: std.ArrayListUnmanaged(SessionRecord),
    started: bool,
};

const ConnectionRecord = struct {
    connection: *runtime.ResourceHandle,
    peer: *runtime.ResourceHandle,
    route_state: u32,
};

const PendingMessage = struct {
    sequence: u64,
    buffer: CBuffer,
};

const ChannelRecord = struct {
    channel: *runtime.ResourceHandle,
    connection: *runtime.ResourceHandle,
    mode: u32,
    next_sequence: u64 = 0,
    last_acknowledged: ?u64 = null,
    pending_messages: std.ArrayListUnmanaged(PendingMessage) = .empty,
};

const SessionRecord = struct {
    session: *runtime.ResourceHandle,
    max_clients: usize,
    admission_context: ?*anyopaque,
    admission: ?CAdmissionFn,
    clients: std.ArrayListUnmanaged(*runtime.ResourceHandle) = .empty,
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

pub fn is_valid_address(address: CAddress) bool {
    switch (address.family) {
        @intFromEnum(CAddressFamily.unspecified), @intFromEnum(CAddressFamily.ipv6) => return true,
        @intFromEnum(CAddressFamily.ipv4) => return std.mem.allEqual(u8, address.bytes[4..], 0),
        else => return false,
    }
}

pub fn is_valid_socket_options(options: CSocketOptions) bool {
    return options.reuse_address <= 1 and options.no_delay <= 1;
}

pub fn is_valid_transport_control(control: CTransportControl) bool {
    return control.connect_timeout_ns >= 0 and control.idle_timeout_ns >= 0;
}

pub fn validate_transport_config(config: ?*const CTransportConfig) CResult {
    const value = config orelse return .invalid_argument;
    if (value.kind != c_transport_udp and value.kind != c_transport_tcp) return .invalid_argument;
    if (!is_valid_address(value.local_address) or !is_valid_address(value.remote_address)) return .invalid_argument;
    if (!is_valid_socket_options(value.socket_options) or !is_valid_transport_control(value.control)) return .invalid_argument;
    return .ok;
}

pub fn is_valid_route_state(route_state: u32) bool {
    return route_state == c_route_direct or route_state == c_route_relay;
}

pub fn is_valid_channel_mode(mode: u32) bool {
    return mode == c_channel_reliable or mode == c_channel_sequenced;
}

pub fn is_nonempty_buffer(buffer: CBuffer) bool {
    return is_valid_buffer(buffer) and buffer.len > 0;
}

pub fn validate_security_config(config: ?*const CSecurityConfig) CResult {
    const value = config orelse return .invalid_argument;
    if (value.flags & ~all_security_flags != 0) return .invalid_argument;
    if (value.flags & c_security_psk != 0 and !is_nonempty_buffer(value.psk)) return .invalid_argument;
    if (value.flags & c_security_public_key != 0 and !is_nonempty_buffer(value.public_key)) return .invalid_argument;
    if (value.flags & c_security_aead != 0 and !is_nonempty_buffer(value.aead_key)) return .invalid_argument;
    if (value.flags & c_security_replay_protection != 0 and value.replay_window == 0) return .invalid_argument;
    if (value.flags & c_security_key_rotation != 0 and (value.rotation_interval_ns <= 0 or value.rotation_overlap_ns < 0)) return .invalid_argument;
    return .ok;
}

pub fn validate_authoritative_session_config(config: ?*const CAuthoritativeSessionConfig) CResult {
    const value = config orelse return .invalid_argument;
    if (value.max_clients == 0) return .invalid_argument;
    return .ok;
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

fn find_connection(state: *CSdkState, connection: *CConnection) ?usize {
    const handle: *runtime.ResourceHandle = @ptrCast(connection);
    state.connections.validate(handle) catch return null;
    for (state.connection_records.items, 0..) |record, index| {
        if (record.connection == handle) return index;
    }
    return null;
}

fn find_channel(state: *CSdkState, channel: *CChannel) ?usize {
    const handle: *runtime.ResourceHandle = @ptrCast(channel);
    state.channels.validate(handle) catch return null;
    for (state.channel_records.items, 0..) |record, index| {
        if (record.channel == handle) return index;
    }
    return null;
}

fn find_session(state: *CSdkState, session: *CAuthoritativeSession) ?usize {
    const handle: *runtime.ResourceHandle = @ptrCast(session);
    state.sessions.validate(handle) catch return null;
    for (state.session_records.items, 0..) |record, index| {
        if (record.session == handle) return index;
    }
    return null;
}

fn discard_pending_messages(state: *CSdkState, record: *ChannelRecord) void {
    for (record.pending_messages.items) |message| release_buffer(state.allocator_bridge.c_allocator, message.buffer) catch {};
    record.pending_messages.clearRetainingCapacity();
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
    state.connections = runtime.ResourceRegistry.init(state.allocator_bridge.allocator(), value.connection_capacity) catch {
        initial_allocator.destroy(state);
        return @intFromEnum(CResult.resource_exhausted);
    };
    state.peers = runtime.ResourceRegistry.init(state.allocator_bridge.allocator(), value.connection_capacity) catch {
        state.connections.deinit();
        initial_allocator.destroy(state);
        return @intFromEnum(CResult.resource_exhausted);
    };
    state.channels = runtime.ResourceRegistry.init(state.allocator_bridge.allocator(), value.channel_capacity) catch {
        state.peers.deinit();
        state.connections.deinit();
        initial_allocator.destroy(state);
        return @intFromEnum(CResult.resource_exhausted);
    };
    state.sessions = runtime.ResourceRegistry.init(state.allocator_bridge.allocator(), value.connection_capacity) catch {
        state.channels.deinit();
        state.peers.deinit();
        state.connections.deinit();
        initial_allocator.destroy(state);
        return @intFromEnum(CResult.resource_exhausted);
    };
    state.connection_records = .empty;
    state.channel_records = .empty;
    state.session_records = .empty;
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
    for (state.channel_records.items) |*record| {
        discard_pending_messages(state, record);
        record.pending_messages.deinit(allocator);
    }
    state.channel_records.deinit(allocator);
    state.channels.deinit();
    for (state.session_records.items) |*record| record.clients.deinit(allocator);
    state.session_records.deinit(allocator);
    state.sessions.deinit();
    state.connection_records.deinit(allocator);
    state.peers.deinit();
    state.connections.deinit();
    state.poll_runtime.deinit();
    allocator.destroy(state);
}

pub export fn minna_san_connection_open(sdk: ?*CSdk, route_state: u32, out_connection: ?*?*CConnection, out_peer: ?*?*CPeer) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const connection_output = out_connection orelse return @intFromEnum(CResult.invalid_argument);
    const peer_output = out_peer orelse return @intFromEnum(CResult.invalid_argument);
    connection_output.* = null;
    peer_output.* = null;
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    if (!state.sdk.configuration().is_capability_enabled(.transport)) return @intFromEnum(CResult.unsupported);
    if (!is_valid_route_state(route_state)) return @intFromEnum(CResult.invalid_argument);
    const connection = state.connections.acquire() catch return @intFromEnum(CResult.resource_exhausted);
    const peer = state.peers.acquire() catch {
        state.connections.release(connection) catch {};
        return @intFromEnum(CResult.resource_exhausted);
    };
    state.connection_records.append(state.allocator_bridge.allocator(), .{ .connection = connection, .peer = peer, .route_state = route_state }) catch {
        state.peers.release(peer) catch {};
        state.connections.release(connection) catch {};
        return @intFromEnum(CResult.resource_exhausted);
    };
    connection_output.* = @ptrCast(connection);
    peer_output.* = @ptrCast(peer);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_connection_close(sdk: ?*CSdk, connection: ?*CConnection) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    const handle = connection orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_connection(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    const raw_connection: *runtime.ResourceHandle = @ptrCast(handle);
    for (state.channel_records.items) |record| {
        if (record.connection == raw_connection) return @intFromEnum(CResult.invalid_state);
    }
    for (state.session_records.items) |record| {
        for (record.clients.items) |client| {
            if (client == raw_connection) return @intFromEnum(CResult.invalid_state);
        }
    }
    const record = state.connection_records.items[index];
    state.peers.release(record.peer) catch return @intFromEnum(CResult.invalid_state);
    state.connections.release(record.connection) catch return @intFromEnum(CResult.invalid_state);
    for (state.connection_records.items[index + 1 ..], index..) |next, destination| state.connection_records.items[destination] = next;
    state.connection_records.items.len -= 1;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_connection_peer(sdk: ?*CSdk, connection: ?*CConnection, out_peer: ?*?*CPeer) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_peer orelse return @intFromEnum(CResult.invalid_argument);
    output.* = null;
    const handle = connection orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_connection(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    output.* = @ptrCast(state.connection_records.items[index].peer);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_connection_route_state(sdk: ?*CSdk, connection: ?*CConnection, out_route_state: ?*u32) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_route_state orelse return @intFromEnum(CResult.invalid_argument);
    const handle = connection orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_connection(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    output.* = state.connection_records.items[index].route_state;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_connection_set_route_state(sdk: ?*CSdk, connection: ?*CConnection, route_state: u32) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_valid_route_state(route_state)) return @intFromEnum(CResult.invalid_argument);
    const handle = connection orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_connection(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    state.connection_records.items[index].route_state = route_state;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_channel_open(sdk: ?*CSdk, connection: ?*CConnection, mode: u32, out_channel: ?*?*CChannel) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_channel orelse return @intFromEnum(CResult.invalid_argument);
    output.* = null;
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    if (!is_valid_channel_mode(mode)) return @intFromEnum(CResult.invalid_argument);
    const connection_handle = connection orelse return @intFromEnum(CResult.invalid_argument);
    _ = find_connection(state, connection_handle) orelse return @intFromEnum(CResult.invalid_argument);
    const channel = state.channels.acquire() catch return @intFromEnum(CResult.resource_exhausted);
    const raw_connection: *runtime.ResourceHandle = @ptrCast(connection_handle);
    state.channel_records.append(state.allocator_bridge.allocator(), .{ .channel = channel, .connection = raw_connection, .mode = mode }) catch {
        state.channels.release(channel) catch {};
        return @intFromEnum(CResult.resource_exhausted);
    };
    output.* = @ptrCast(channel);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_channel_close(sdk: ?*CSdk, channel: ?*CChannel) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    const handle = channel orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_channel(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    var record = state.channel_records.items[index];
    discard_pending_messages(state, &record);
    record.pending_messages.deinit(state.allocator_bridge.allocator());
    state.channels.release(record.channel) catch return @intFromEnum(CResult.invalid_state);
    for (state.channel_records.items[index + 1 ..], index..) |next, destination| state.channel_records.items[destination] = next;
    state.channel_records.items.len -= 1;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_channel_mode(sdk: ?*CSdk, channel: ?*CChannel, out_mode: ?*u32) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_mode orelse return @intFromEnum(CResult.invalid_argument);
    const handle = channel orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_channel(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    output.* = state.channel_records.items[index].mode;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_channel_send(sdk: ?*CSdk, channel: ?*CChannel, buffer: CBuffer, out_sequence: ?*u64) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_sequence orelse return @intFromEnum(CResult.invalid_argument);
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    if (!is_valid_buffer(buffer)) return @intFromEnum(CResult.invalid_argument);
    const handle = channel orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_channel(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    var record = &state.channel_records.items[index];
    const copied = allocate_buffer(state.allocator_bridge.c_allocator, buffer.len) catch return @intFromEnum(CResult.resource_exhausted);
    if (buffer.len > 0) {
        const source: [*]const u8 = @ptrCast(buffer.data);
        const destination: [*]u8 = @ptrCast(copied.data);
        @memcpy(destination[0..buffer.len], source[0..buffer.len]);
    }
    if (record.mode == c_channel_sequenced) discard_pending_messages(state, record);
    const sequence = record.next_sequence;
    record.pending_messages.append(state.allocator_bridge.allocator(), .{ .sequence = sequence, .buffer = copied }) catch {
        release_buffer(state.allocator_bridge.c_allocator, copied) catch {};
        return @intFromEnum(CResult.resource_exhausted);
    };
    record.next_sequence +%= 1;
    output.* = sequence;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_channel_receive(sdk: ?*CSdk, channel: ?*CChannel, out_buffer: ?*CBuffer, out_sequence: ?*u64) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const buffer_output = out_buffer orelse return @intFromEnum(CResult.invalid_argument);
    const sequence_output = out_sequence orelse return @intFromEnum(CResult.invalid_argument);
    buffer_output.* = .{ .data = null, .len = 0 };
    sequence_output.* = 0;
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    const handle = channel orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_channel(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    var record = &state.channel_records.items[index];
    if (record.pending_messages.items.len == 0) return @intFromEnum(CResult.would_block);
    const message = record.pending_messages.items[0];
    for (record.pending_messages.items[1..], 0..) |next, destination| record.pending_messages.items[destination] = next;
    record.pending_messages.items.len -= 1;
    buffer_output.* = message.buffer;
    sequence_output.* = message.sequence;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_channel_acknowledge(sdk: ?*CSdk, channel: ?*CChannel, sequence: u64) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const handle = channel orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_channel(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    var record = &state.channel_records.items[index];
    if (sequence >= record.next_sequence) return @intFromEnum(CResult.invalid_argument);
    if (record.last_acknowledged) |last| {
        if (sequence < last) return @intFromEnum(CResult.invalid_argument);
    }
    record.last_acknowledged = sequence;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_channel_last_acknowledged(sdk: ?*CSdk, channel: ?*CChannel, out_sequence: ?*u64) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_sequence orelse return @intFromEnum(CResult.invalid_argument);
    const handle = channel orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_channel(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    output.* = state.channel_records.items[index].last_acknowledged orelse return @intFromEnum(CResult.would_block);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_sdk_buffer_release(sdk: ?*CSdk, buffer: CBuffer) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    release_buffer(state.allocator_bridge.c_allocator, buffer) catch return @intFromEnum(CResult.invalid_argument);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_security_config_init(out_config: ?*CSecurityConfig) c_int {
    const output = out_config orelse return @intFromEnum(CResult.invalid_argument);
    output.* = .{
        .flags = 0,
        .psk = .{ .data = null, .len = 0 },
        .public_key = .{ .data = null, .len = 0 },
        .aead_key = .{ .data = null, .len = 0 },
        .replay_window = 0,
        .rotation_interval_ns = 0,
        .rotation_overlap_ns = 0,
    };
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_security_config_set_psk(config: ?*CSecurityConfig, psk: CBuffer) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_nonempty_buffer(psk)) return @intFromEnum(CResult.invalid_argument);
    value.flags |= c_security_psk;
    value.psk = psk;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_security_config_set_public_key(config: ?*CSecurityConfig, public_key: CBuffer) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_nonempty_buffer(public_key)) return @intFromEnum(CResult.invalid_argument);
    value.flags |= c_security_public_key;
    value.public_key = public_key;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_security_config_set_aead_key(config: ?*CSecurityConfig, aead_key: CBuffer) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_nonempty_buffer(aead_key)) return @intFromEnum(CResult.invalid_argument);
    value.flags |= c_security_aead;
    value.aead_key = aead_key;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_security_config_set_replay_window(config: ?*CSecurityConfig, replay_window: u32) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (replay_window == 0) return @intFromEnum(CResult.invalid_argument);
    value.flags |= c_security_replay_protection;
    value.replay_window = replay_window;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_security_config_set_key_rotation(config: ?*CSecurityConfig, interval_ns: CDurationNs, overlap_ns: CDurationNs) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (interval_ns <= 0 or overlap_ns < 0) return @intFromEnum(CResult.invalid_argument);
    value.flags |= c_security_key_rotation;
    value.rotation_interval_ns = interval_ns;
    value.rotation_overlap_ns = overlap_ns;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_security_config_validate(config: ?*const CSecurityConfig) c_int {
    return @intFromEnum(validate_security_config(config));
}

pub export fn minna_san_authoritative_session_config_init(out_config: ?*CAuthoritativeSessionConfig) c_int {
    const output = out_config orelse return @intFromEnum(CResult.invalid_argument);
    output.* = .{ .max_clients = 1, .admission_context = null, .admission = null };
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_authoritative_session_config_validate(config: ?*const CAuthoritativeSessionConfig) c_int {
    return @intFromEnum(validate_authoritative_session_config(config));
}

pub export fn minna_san_authoritative_session_create(sdk: ?*CSdk, config: ?*const CAuthoritativeSessionConfig, out_session: ?*?*CAuthoritativeSession) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_session orelse return @intFromEnum(CResult.invalid_argument);
    output.* = null;
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    if (!state.sdk.configuration().is_capability_enabled(.topology)) return @intFromEnum(CResult.unsupported);
    if (validate_authoritative_session_config(config) != .ok) return @intFromEnum(validate_authoritative_session_config(config));
    const handle = state.sessions.acquire() catch return @intFromEnum(CResult.resource_exhausted);
    const value = config.?;
    state.session_records.append(state.allocator_bridge.allocator(), .{ .session = handle, .max_clients = value.max_clients, .admission_context = value.admission_context, .admission = value.admission }) catch {
        state.sessions.release(handle) catch {};
        return @intFromEnum(CResult.resource_exhausted);
    };
    output.* = @ptrCast(handle);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_authoritative_session_destroy(sdk: ?*CSdk, session: ?*CAuthoritativeSession) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const handle = session orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_session(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    var record = state.session_records.items[index];
    record.clients.deinit(state.allocator_bridge.allocator());
    state.sessions.release(record.session) catch return @intFromEnum(CResult.invalid_state);
    for (state.session_records.items[index + 1 ..], index..) |next, destination| state.session_records.items[destination] = next;
    state.session_records.items.len -= 1;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_authoritative_session_client_join(sdk: ?*CSdk, session: ?*CAuthoritativeSession, connection: ?*CConnection) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    if (!state.started) return @intFromEnum(CResult.invalid_state);
    const session_handle = session orelse return @intFromEnum(CResult.invalid_argument);
    const session_index = find_session(state, session_handle) orelse return @intFromEnum(CResult.invalid_argument);
    const connection_handle = connection orelse return @intFromEnum(CResult.invalid_argument);
    const connection_index = find_connection(state, connection_handle) orelse return @intFromEnum(CResult.invalid_argument);
    var record = &state.session_records.items[session_index];
    for (record.clients.items) |client| {
        if (client == @as(*runtime.ResourceHandle, @ptrCast(connection_handle))) return @intFromEnum(CResult.invalid_state);
    }
    if (record.clients.items.len == record.max_clients) return @intFromEnum(CResult.resource_exhausted);
    if (record.admission) |admission| {
        const peer: *const CPeer = @ptrCast(state.connection_records.items[connection_index].peer);
        if (admission(record.admission_context, peer) != c_admission_accept) return @intFromEnum(CResult.permission_denied);
    }
    record.clients.append(state.allocator_bridge.allocator(), @ptrCast(connection_handle)) catch return @intFromEnum(CResult.resource_exhausted);
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_authoritative_session_client_leave(sdk: ?*CSdk, session: ?*CAuthoritativeSession, connection: ?*CConnection) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const session_handle = session orelse return @intFromEnum(CResult.invalid_argument);
    const session_index = find_session(state, session_handle) orelse return @intFromEnum(CResult.invalid_argument);
    const connection_handle = connection orelse return @intFromEnum(CResult.invalid_argument);
    const raw_connection: *runtime.ResourceHandle = @ptrCast(connection_handle);
    var record = &state.session_records.items[session_index];
    for (record.clients.items, 0..) |client, index| {
        if (client != raw_connection) continue;
        for (record.clients.items[index + 1 ..], index..) |next, destination| record.clients.items[destination] = next;
        record.clients.items.len -= 1;
        return @intFromEnum(CResult.ok);
    }
    return @intFromEnum(CResult.invalid_argument);
}

pub export fn minna_san_authoritative_session_client_count(sdk: ?*CSdk, session: ?*CAuthoritativeSession, out_count: ?*usize) c_int {
    const state = state_from_handle(sdk) orelse return @intFromEnum(CResult.invalid_argument);
    const output = out_count orelse return @intFromEnum(CResult.invalid_argument);
    const handle = session orelse return @intFromEnum(CResult.invalid_argument);
    const index = find_session(state, handle) orelse return @intFromEnum(CResult.invalid_argument);
    output.* = state.session_records.items[index].clients.items.len;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_event_kind(event: ?*const CEvent) u32 {
    return (event orelse return 0).kind;
}

pub export fn minna_san_event_mode(event: ?*const CEvent) u32 {
    return (event orelse return 0).mode;
}

pub export fn minna_san_event_sequence(event: ?*const CEvent) u64 {
    return (event orelse return 0).sequence;
}

pub export fn minna_san_event_payload(event: ?*const CEvent) CBuffer {
    return (event orelse return .{ .data = null, .len = 0 }).payload;
}

pub export fn minna_san_transport_config_init(out_config: ?*CTransportConfig) c_int {
    const output = out_config orelse return @intFromEnum(CResult.invalid_argument);
    output.* = .{
        .kind = c_transport_udp,
        .local_address = .{ .family = @intFromEnum(CAddressFamily.unspecified), .bytes = [_]u8{0} ** 16, .port = 0 },
        .remote_address = .{ .family = @intFromEnum(CAddressFamily.unspecified), .bytes = [_]u8{0} ** 16, .port = 0 },
        .socket_options = .{ .send_buffer_bytes = 0, .receive_buffer_bytes = 0, .reuse_address = 0, .no_delay = 0, .reserved = .{ 0, 0 } },
        .control = .{ .connect_timeout_ns = 0, .idle_timeout_ns = 0, .max_datagram_bytes = 0, .max_in_flight = 0 },
    };
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_transport_config_set_kind(config: ?*CTransportConfig, kind: u32) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (kind != c_transport_udp and kind != c_transport_tcp) return @intFromEnum(CResult.invalid_argument);
    value.kind = kind;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_transport_config_set_local_address(config: ?*CTransportConfig, address: CAddress) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_valid_address(address)) return @intFromEnum(CResult.invalid_argument);
    value.local_address = address;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_transport_config_set_remote_address(config: ?*CTransportConfig, address: CAddress) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_valid_address(address)) return @intFromEnum(CResult.invalid_argument);
    value.remote_address = address;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_transport_config_set_socket_options(config: ?*CTransportConfig, options: CSocketOptions) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_valid_socket_options(options)) return @intFromEnum(CResult.invalid_argument);
    value.socket_options = options;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_transport_config_set_control(config: ?*CTransportConfig, control: CTransportControl) c_int {
    const value = config orelse return @intFromEnum(CResult.invalid_argument);
    if (!is_valid_transport_control(control)) return @intFromEnum(CResult.invalid_argument);
    value.control = control;
    return @intFromEnum(CResult.ok);
}

pub export fn minna_san_transport_config_validate(config: ?*const CTransportConfig) c_int {
    return @intFromEnum(validate_transport_config(config));
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
        var released: bool = false;

        fn allocate(_: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return @ptrCast(bytes.ptr);
        }

        fn release(_: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) void {
            const bytes: [*]u8 = @ptrCast(data);
            std.testing.allocator.free(bytes[0..len]);
            released = true;
        }

        fn now(_: ?*anyopaque) callconv(.c) core.TimeNs {
            return 42;
        }
    };
    Fixture.released = false;
    const config = CSdkConfig{
        .abi_version = c_abi_version,
        .capability_bits = c_capability_transport,
        .connection_capacity = 2,
        .channel_capacity = 2,
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
    var connection: ?*CConnection = null;
    var peer: ?*CPeer = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_connection_open(sdk, c_route_direct, &connection, &peer));
    try std.testing.expect(connection != null and peer != null);
    var returned_peer: ?*CPeer = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_connection_peer(sdk, connection, &returned_peer));
    try std.testing.expectEqual(@intFromPtr(peer.?), @intFromPtr(returned_peer.?));
    var route_state: u32 = 0;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_connection_route_state(sdk, connection, &route_state));
    try std.testing.expectEqual(c_route_direct, route_state);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_connection_set_route_state(sdk, connection, c_route_relay));
    var reliable_channel: ?*CChannel = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_open(sdk, connection, c_channel_reliable, &reliable_channel));
    var message = [_]u8{ 'o', 'k' };
    var sent_sequence: u64 = 0;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_send(sdk, reliable_channel, .{ .data = @ptrCast(&message), .len = message.len }, &sent_sequence));
    var received = CBuffer{ .data = null, .len = 0 };
    var received_sequence: u64 = 0;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_receive(sdk, reliable_channel, &received, &received_sequence));
    try std.testing.expectEqual(sent_sequence, received_sequence);
    const received_bytes: [*]const u8 = @ptrCast(received.data);
    try std.testing.expectEqualSlices(u8, &message, received_bytes[0..received.len]);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_acknowledge(sdk, reliable_channel, received_sequence));
    var acknowledged_sequence: u64 = 0;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_last_acknowledged(sdk, reliable_channel, &acknowledged_sequence));
    try std.testing.expectEqual(received_sequence, acknowledged_sequence);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_buffer_release(sdk, received));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.would_block)), minna_san_channel_receive(sdk, reliable_channel, &received, &received_sequence));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_close(sdk, reliable_channel));
    var sequenced_channel: ?*CChannel = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_open(sdk, connection, c_channel_sequenced, &sequenced_channel));
    var first = [_]u8{'a'};
    var second = [_]u8{'b'};
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_send(sdk, sequenced_channel, .{ .data = @ptrCast(&first), .len = first.len }, &sent_sequence));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_send(sdk, sequenced_channel, .{ .data = @ptrCast(&second), .len = second.len }, &sent_sequence));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_receive(sdk, sequenced_channel, &received, &received_sequence));
    const sequenced_bytes: [*]const u8 = @ptrCast(received.data);
    try std.testing.expectEqualSlices(u8, &second, sequenced_bytes[0..received.len]);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_buffer_release(sdk, received));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_channel_close(sdk, sequenced_channel));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_connection_close(sdk, connection));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_connection_route_state(sdk, connection, &route_state));
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
        .connection_capacity = 0,
        .channel_capacity = 0,
        .clock_context = null,
        .now = null,
        .allocator = .{ .context = null, .allocate = null, .release = null },
    };
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_validate_config(&invalid));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_start(null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_poll(null, null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_sdk_stop(null));
}

test "C connection and event accessors reject invalid inputs" {
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_connection_open(null, c_route_direct, null, null));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_connection_set_route_state(null, null, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_channel_open(null, null, 0, null));
    const event = CEvent{ .kind = @intFromEnum(CEventKind.message), .mode = 2, .sequence = 3, .payload = .{ .data = @ptrFromInt(1), .len = 4 } };
    try std.testing.expectEqual(@intFromEnum(CEventKind.message), minna_san_event_kind(&event));
    try std.testing.expectEqual(@as(u32, 2), minna_san_event_mode(&event));
    try std.testing.expectEqual(@as(u64, 3), minna_san_event_sequence(&event));
    try std.testing.expectEqual(@as(usize, 4), minna_san_event_payload(&event).len);
    try std.testing.expectEqual(@as(u32, 0), minna_san_event_kind(null));
    try std.testing.expectEqual(@as(usize, 0), minna_san_event_payload(null).len);
}

test "C security configuration borrows caller key buffers without copies" {
    var config: CSecurityConfig = undefined;
    var psk = [_]u8{ 1, 2 };
    var public_key = [_]u8{3};
    var aead_key = [_]u8{ 4, 5, 6 };
    const psk_buffer = CBuffer{ .data = @ptrCast(&psk), .len = psk.len };
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_security_config_init(&config));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_security_config_set_psk(&config, psk_buffer));
    try std.testing.expectEqual(@intFromPtr(psk_buffer.data), @intFromPtr(config.psk.data));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_security_config_set_public_key(&config, .{ .data = @ptrCast(&public_key), .len = public_key.len }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_security_config_set_aead_key(&config, .{ .data = @ptrCast(&aead_key), .len = aead_key.len }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_security_config_set_replay_window(&config, 64));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_security_config_set_key_rotation(&config, 10, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_security_config_validate(&config));
}

test "C security configuration rejects absent keys and invalid controls" {
    var config: CSecurityConfig = undefined;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_security_config_init(null));
    _ = minna_san_security_config_init(&config);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_security_config_set_psk(&config, .{ .data = null, .len = 0 }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_security_config_set_replay_window(&config, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_security_config_set_key_rotation(&config, 0, -1));
    config.flags = c_security_aead;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_security_config_validate(&config));
}

test "C authoritative sessions enforce admission and client capacity" {
    const Fixture = struct {
        fn allocate(_: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return @ptrCast(bytes.ptr);
        }

        fn release(_: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) void {
            const bytes: [*]u8 = @ptrCast(data);
            std.testing.allocator.free(bytes[0..len]);
        }

        fn now(_: ?*anyopaque) callconv(.c) core.TimeNs {
            return 0;
        }

        fn reject(_: ?*anyopaque, _: *const CPeer) callconv(.c) u32 {
            return c_admission_reject;
        }
    };
    const sdk_config = CSdkConfig{
        .abi_version = c_abi_version,
        .capability_bits = c_capability_transport | c_capability_topology,
        .connection_capacity = 1,
        .channel_capacity = 0,
        .clock_context = null,
        .now = Fixture.now,
        .allocator = .{ .context = null, .allocate = Fixture.allocate, .release = Fixture.release },
    };
    var sdk: ?*CSdk = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_create(&sdk_config, &sdk));
    defer minna_san_sdk_destroy(sdk);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_sdk_start(sdk));
    var connection: ?*CConnection = null;
    var peer: ?*CPeer = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_connection_open(sdk, c_route_direct, &connection, &peer));
    var session_config = CAuthoritativeSessionConfig{ .max_clients = 1, .admission_context = null, .admission = null };
    var session: ?*CAuthoritativeSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_authoritative_session_create(sdk, &session_config, &session));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_authoritative_session_client_join(sdk, session, connection));
    var count: usize = 0;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_authoritative_session_client_count(sdk, session, &count));
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_state)), minna_san_authoritative_session_client_join(sdk, session, connection));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_authoritative_session_client_leave(sdk, session, connection));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_authoritative_session_destroy(sdk, session));
    session_config.admission = Fixture.reject;
    var rejected_session: ?*CAuthoritativeSession = null;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_authoritative_session_create(sdk, &session_config, &rejected_session));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.permission_denied)), minna_san_authoritative_session_client_join(sdk, rejected_session, connection));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_authoritative_session_destroy(sdk, rejected_session));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_connection_close(sdk, connection));
}

test "C transport builders configure valid selection addresses options and controls" {
    var config: CTransportConfig = undefined;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_transport_config_init(&config));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_transport_config_set_kind(&config, c_transport_tcp));
    const address = CAddress{ .family = @intFromEnum(CAddressFamily.ipv4), .bytes = .{ 127, 0, 0, 1 } ++ [_]u8{0} ** 12, .port = 7777 };
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_transport_config_set_local_address(&config, address));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_transport_config_set_remote_address(&config, address));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_transport_config_set_socket_options(&config, .{ .send_buffer_bytes = 1, .receive_buffer_bytes = 2, .reuse_address = 1, .no_delay = 1, .reserved = .{ 0, 0 } }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_transport_config_set_control(&config, .{ .connect_timeout_ns = 1, .idle_timeout_ns = 2, .max_datagram_bytes = 3, .max_in_flight = 4 }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.ok)), minna_san_transport_config_validate(&config));
}

test "C transport builders reject invalid values" {
    var config: CTransportConfig = undefined;
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_transport_config_init(null));
    _ = minna_san_transport_config_init(&config);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_transport_config_set_kind(&config, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_transport_config_set_local_address(&config, .{ .family = 3, .bytes = [_]u8{0} ** 16, .port = 0 }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_transport_config_set_socket_options(&config, .{ .send_buffer_bytes = 0, .receive_buffer_bytes = 0, .reuse_address = 2, .no_delay = 0, .reserved = .{ 0, 0 } }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CResult.invalid_argument)), minna_san_transport_config_set_control(&config, .{ .connect_timeout_ns = -1, .idle_timeout_ns = 0, .max_datagram_bytes = 0, .max_in_flight = 0 }));
}
