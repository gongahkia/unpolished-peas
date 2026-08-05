const std = @import("std");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");

pub const max_hostname_addresses: usize = 16;
pub const HostnameResolutionError = error{ InvalidHostname, InvalidState, ThreadStartFailed, NotReady, ResolutionFailed, OutOfMemory };

pub const ResolvedAddress = union(enum) {
    ipv4: ipv4.Ipv4Address,
    ipv6: ipv6.Ipv6Address,
};

pub const HostnameResolutionState = enum {
    pending,
    resolving,
    resolved,
    failed,
};

pub const HostnameResolution = struct {
    allocator: std.mem.Allocator,
    hostname: []u8,
    port: u16,
    lock: std.Thread.Mutex = .{},
    state: HostnameResolutionState = .pending,
    worker: ?std.Thread = null,
    addresses: [max_hostname_addresses]ResolvedAddress = undefined,
    address_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, hostname: []const u8, port: u16) HostnameResolutionError!HostnameResolution {
        if (hostname.len == 0) return error.InvalidHostname;
        return .{
            .allocator = allocator,
            .hostname = allocator.dupe(u8, hostname) catch return error.OutOfMemory,
            .port = port,
        };
    }

    pub fn start(self: *HostnameResolution) HostnameResolutionError!void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.state != .pending) return error.InvalidState;
        self.state = .resolving;
        self.worker = std.Thread.spawn(.{}, resolve_in_worker, .{self}) catch {
            self.state = .pending;
            return error.ThreadStartFailed;
        };
    }

    pub fn status(self: *HostnameResolution) HostnameResolutionState {
        self.lock.lock();
        defer self.lock.unlock();
        return self.state;
    }

    pub fn result(self: *HostnameResolution) HostnameResolutionError![]const ResolvedAddress {
        self.lock.lock();
        defer self.lock.unlock();
        return switch (self.state) {
            .resolved => self.addresses[0..self.address_count],
            .failed => error.ResolutionFailed,
            else => error.NotReady,
        };
    }

    pub fn deinit(self: *HostnameResolution) void {
        if (self.worker) |worker| worker.join();
        self.allocator.free(self.hostname);
        self.* = undefined;
    }
};

fn resolve_in_worker(resolution: *HostnameResolution) void {
    const address_list = std.net.getAddressList(resolution.allocator, resolution.hostname, resolution.port) catch {
        resolution.lock.lock();
        resolution.state = .failed;
        resolution.lock.unlock();
        return;
    };
    defer address_list.deinit();

    resolution.lock.lock();
    defer resolution.lock.unlock();
    for (address_list.addrs) |address| {
        if (resolution.address_count == max_hostname_addresses) break;
        const resolved = switch (address.any.family) {
            std.posix.AF.INET => ResolvedAddress{ .ipv4 = ipv4.Ipv4Address.from_native(address) catch continue },
            std.posix.AF.INET6 => ResolvedAddress{ .ipv6 = ipv6.Ipv6Address.from_native(address) catch continue },
            else => continue,
        };
        resolution.addresses[resolution.address_count] = resolved;
        resolution.address_count += 1;
    }
    resolution.state = if (resolution.address_count == 0) .failed else .resolved;
}

test "hostname resolution completes asynchronously with bounded address results" {
    var resolution = try HostnameResolution.init(std.testing.allocator, "localhost", 9000);
    defer resolution.deinit();
    try std.testing.expectError(error.NotReady, resolution.result());
    try resolution.start();
    try std.testing.expectError(error.InvalidState, resolution.start());
    var attempts: usize = 0;
    while (resolution.status() == .resolving and attempts < 1_000) : (attempts += 1) std.Thread.sleep(std.time.ns_per_ms);
    try std.testing.expectEqual(HostnameResolutionState.resolved, resolution.status());
    const addresses = try resolution.result();
    try std.testing.expect(addresses.len > 0);
    try std.testing.expect(addresses.len <= max_hostname_addresses);
}

test "hostname resolution rejects invalid request construction" {
    try std.testing.expectError(error.InvalidHostname, HostnameResolution.init(std.testing.allocator, "", 1));
}
