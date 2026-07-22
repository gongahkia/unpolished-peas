const std = @import("std");
const runtime = @import("minna-san-runtime");
const native = @cImport({
    @cInclude("msquic_lifecycle_native.h");
});

fn nativeOpen(context: ?*anyopaque, connection_id: u64, role: runtime.QuicConnectionRole, callback_context: ?*anyopaque, callback: runtime.QuicConnectionCallback) callconv(.c) c_int {
    const fixture: ?*native.minna_msquic_lifecycle_fixture = @ptrCast(@alignCast(context));
    const native_callback: native.minna_quic_connection_callback = @ptrCast(callback);
    return native.minna_msquic_lifecycle_fixture_open(fixture, connection_id, @intFromEnum(role), callback_context, native_callback);
}

fn nativeShutdown(context: ?*anyopaque, connection_id: u64) callconv(.c) void {
    const fixture: ?*native.minna_msquic_lifecycle_fixture = @ptrCast(@alignCast(context));
    native.minna_msquic_lifecycle_fixture_shutdown(fixture, connection_id);
}

fn session_state(lifecycle: *runtime.QuicConnectionLifecycle, handle: *runtime.ResourceHandle) !runtime.SessionState {
    return (try lifecycle.status(handle)).state;
}

fn poll_until(lifecycle: *runtime.QuicConnectionLifecycle, first: *runtime.ResourceHandle, second: *runtime.ResourceHandle, expected: runtime.SessionState) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        _ = try lifecycle.poll(@intCast(std.time.nanoTimestamp()), 16);
        const first_state = session_state(lifecycle, first) catch |err| switch (err) {
            error.StaleHandle => if (expected == .closed) runtime.SessionState.closed else return err,
            else => return err,
        };
        const second_state = session_state(lifecycle, second) catch |err| switch (err) {
            error.StaleHandle => if (expected == .closed) runtime.SessionState.closed else return err,
            else => return err,
        };
        if (first_state == expected and second_state == expected) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

pub fn main() !void {
    var arguments = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer arguments.deinit();
    _ = arguments.next();
    const certificate_path = arguments.next() orelse return error.InvalidArguments;
    const private_key_path = arguments.next() orelse return error.InvalidArguments;
    if (arguments.next() != null) return error.InvalidArguments;

    var fixture: ?*native.minna_msquic_lifecycle_fixture = null;
    if (native.minna_msquic_lifecycle_fixture_init(&fixture, certificate_path.ptr, private_key_path.ptr) != 0) return error.NativeProviderFailed;
    defer native.minna_msquic_lifecycle_fixture_deinit(fixture);

    var resources = try runtime.ResourceRegistry.init(std.heap.page_allocator, 2);
    defer resources.deinit();
    var sessions = try runtime.SessionRegistry.init(std.heap.page_allocator, &resources, 2);
    defer sessions.deinit();
    var lifecycle = try runtime.QuicConnectionLifecycle.init(std.heap.page_allocator, &sessions, .{ .maximum_connections = 2, .maximum_events = 16 }, fixture, .{ .open = nativeOpen, .shutdown = nativeShutdown });
    defer lifecycle.deinit();

    const server = try lifecycle.connect(.{ .role = .server }, @intCast(std.time.nanoTimestamp()));
    const client = try lifecycle.connect(.{ .role = .client }, @intCast(std.time.nanoTimestamp()));
    try poll_until(&lifecycle, server, client, .ready);
    try lifecycle.close(client);
    try poll_until(&lifecycle, server, client, .closed);
    try std.fs.File.stdout().deprecatedWriter().writeAll("msquic-lifecycle=established-and-closed-under-poll\n");
}
