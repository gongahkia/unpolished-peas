const std = @import("std");
const core = @import("minna-san-core");
const transport = @import("minna-san-transport");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const runtime = @import("minna-san-runtime");
const c_abi = @import("minna-san-c-abi");

fn core_and_state_lifecycle(allocator: std.mem.Allocator) !void {
    const Simulation = struct {
        fn accept(_: ?*anyopaque, _: state.StatePredictionInput) bool {
            return true;
        }
    };
    var owned = try core.OwnedBuffer.initCopy(allocator, "owned");
    defer owned.deinit();
    var prediction = try state.StateClientPrediction.init(allocator, .{ .maximum_history = 1, .maximum_input_bytes = 1, .simulation_context = null, .simulate = Simulation.accept });
    defer prediction.deinit();
    _ = try prediction.submit("x");
    prediction.acknowledge_through(0);
}

fn transport_lifecycle(allocator: std.mem.Allocator) !void {
    var pool = try transport.PacketBufferPool.init(allocator, .{ .packet_capacity = 8, .pooled_buffers = 1, .fallback_buffers = 1 });
    defer pool.deinit();
    var pooled = try pool.acquire();
    defer pool.release(&pooled) catch unreachable;
    var fallback = try pool.acquire();
    defer pool.release(&fallback) catch unreachable;
}

fn topology_lifecycle(allocator: std.mem.Allocator) !void {
    var groups = try topology.RoutedPeerGroups.init(allocator, .{ .maximum_groups = 1, .maximum_routes_per_group = 1 });
    defer groups.deinit();
    try groups.create(1);
    try groups.add_route(1, .{ .peer = 1, .path = .{ .direct = 1 } });
    try groups.close(1);
    try groups.destroy(1);

    var directory = try topology.ShardDirectory.init(allocator, .{ .maximum_shards = 2 });
    defer directory.deinit();
    try directory.register(.{ .id = 1, .capacity = .{ .maximum_participants = 1, .active_participants = 1 }, .health = .healthy, .route = .{ .id = 1, .kind = .authoritative, .endpoint = topology.ShardEndpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 9000 }) } });
    try directory.register(.{ .id = 2, .capacity = .{ .maximum_participants = 1, .active_participants = 0 }, .health = .healthy, .route = .{ .id = 2, .kind = .authoritative, .endpoint = topology.ShardEndpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 2 }, .port = 9001 }) } });
    var handoff = try topology.ShardHandoffCoordinator.init(allocator, &directory, .{ .maximum_pending_handoffs = 1, .maximum_state_bytes = 1 });
    defer handoff.deinit();
    const id = try handoff.prepare(.{ .client = 1, .source = 1, .destination = 2, .state_revision = 1, .state = "x" });
    try handoff.acknowledge(id, 1);
}

fn runtime_lifecycle(allocator: std.mem.Allocator) !void {
    var registry = try runtime.ResourceRegistry.init(allocator, 1);
    defer registry.deinit();
    const handle = try registry.acquire();
    try registry.release(handle);

    const stream_bytes = runtime.capture_stream_header_bytes + runtime.capture_record_header_bytes + 1;
    var recorder = try runtime.CaptureRecorder.init(allocator, .{ .enabled = true, .maximum_stream_bytes = stream_bytes });
    defer recorder.deinit();
    try recorder.record(.{ .kind = .event, .sequence = 0, .timestamp_ns = 0, .payload = "x" });
}

const CAllocatorFixture = struct {
    allocator: std.mem.Allocator,
    remaining: usize,
    allocations: usize = 0,
    releases: usize = 0,

    fn allocate(context: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
        const value = context orelse return null;
        const self: *@This() = @ptrCast(@alignCast(value));
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const bytes = self.allocator.alloc(u8, len) catch return null;
        self.allocations += 1;
        return @ptrCast(bytes.ptr);
    }

    fn release(context: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) void {
        const value = context orelse return;
        const self: *@This() = @ptrCast(@alignCast(value));
        const bytes: [*]u8 = @ptrCast(data);
        self.allocator.free(bytes[0..len]);
        self.releases += 1;
    }

    fn now(_: ?*anyopaque) callconv(.c) core.TimeNs {
        return 0;
    }
};

fn c_abi_lifecycle(fixture: *CAllocatorFixture) !void {
    const config = c_abi.CSdkConfig{
        .abi_version = c_abi.c_abi_version,
        .capability_bits = c_abi.c_capability_transport,
        .connection_capacity = 1,
        .channel_capacity = 1,
        .platform_config = c_abi.default_platform_config,
        .clock_context = null,
        .now = CAllocatorFixture.now,
        .allocator = .{ .context = fixture, .allocate = CAllocatorFixture.allocate, .release = CAllocatorFixture.release },
    };
    var sdk: ?*c_abi.CSdk = null;
    const created = c_abi.minna_san_sdk_create(&config, &sdk);
    try std.testing.expectEqual(@as(u8, 1), c_abi.minna_san_result_is_known(created));
    if (created != @intFromEnum(c_abi.CResult.ok)) {
        try std.testing.expect(sdk == null);
        return;
    }
    defer c_abi.minna_san_sdk_destroy(sdk);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(c_abi.CResult.ok)), c_abi.minna_san_sdk_start(sdk));
    var connection: ?*c_abi.CConnection = null;
    var peer: ?*c_abi.CPeer = null;
    const opened = c_abi.minna_san_connection_open(sdk, c_abi.c_route_direct, &connection, &peer);
    try std.testing.expectEqual(@as(u8, 1), c_abi.minna_san_result_is_known(opened));
    if (opened == @intFromEnum(c_abi.CResult.ok)) {
        defer std.testing.expectEqual(@as(c_int, @intFromEnum(c_abi.CResult.ok)), c_abi.minna_san_connection_close(sdk, connection)) catch unreachable;
        var channel: ?*c_abi.CChannel = null;
        const channel_opened = c_abi.minna_san_channel_open(sdk, connection, c_abi.c_channel_reliable, &channel);
        try std.testing.expectEqual(@as(u8, 1), c_abi.minna_san_result_is_known(channel_opened));
        if (channel_opened == @intFromEnum(c_abi.CResult.ok)) {
            defer std.testing.expectEqual(@as(c_int, @intFromEnum(c_abi.CResult.ok)), c_abi.minna_san_channel_close(sdk, channel)) catch unreachable;
            var payload = [_]u8{'x'};
            var sequence: u64 = 0;
            const sent = c_abi.minna_san_channel_send(sdk, channel, .{ .data = @ptrCast(&payload), .len = payload.len }, &sequence);
            try std.testing.expectEqual(@as(u8, 1), c_abi.minna_san_result_is_known(sent));
            if (sent == @intFromEnum(c_abi.CResult.ok)) {
                var received = c_abi.CBuffer{ .data = null, .len = 0 };
                var received_sequence: u64 = 0;
                try std.testing.expectEqual(@as(c_int, @intFromEnum(c_abi.CResult.ok)), c_abi.minna_san_channel_receive(sdk, channel, &received, &received_sequence));
                try std.testing.expectEqual(sequence, received_sequence);
                try std.testing.expectEqual(@as(c_int, @intFromEnum(c_abi.CResult.ok)), c_abi.minna_san_sdk_buffer_release(sdk, received));
            }
        }
    }
    try std.testing.expectEqual(@as(c_int, @intFromEnum(c_abi.CResult.ok)), c_abi.minna_san_sdk_stop(sdk));
}

test "public owning lifecycles release every allocation failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, core_and_state_lifecycle, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, transport_lifecycle, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, topology_lifecycle, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runtime_lifecycle, .{});
}

test "C ABI lifecycle releases tracked successful and failing allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var budget: usize = 0;
    while (budget < 32) : (budget += 1) {
        var fixture = CAllocatorFixture{ .allocator = allocator, .remaining = budget };
        try c_abi_lifecycle(&fixture);
        try std.testing.expectEqual(fixture.allocations, fixture.releases);
    }
    var successful = CAllocatorFixture{ .allocator = allocator, .remaining = std.math.maxInt(usize) };
    try c_abi_lifecycle(&successful);
    try std.testing.expect(successful.allocations > 0);
    try std.testing.expectEqual(successful.allocations, successful.releases);
    try std.testing.expect(gpa.deinit() == .ok);
}
