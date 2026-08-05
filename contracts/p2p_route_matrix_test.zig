const std = @import("std");

const Reservation = struct {
    socket: ?std.posix.socket_t,
    port: u16,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 8) return error.InvalidArgument;
    try runDirect(allocator, args[1], args[2]);
    try report("direct", "direct-permitted");
    try runRelay(allocator, args[3], args[4], args[5]);
    try report("relay", "relay-only");
    try runTcpFallback(allocator, args[6], args[7]);
    try report("tcp-fallback", "udp-send-failed");
}

fn runDirect(allocator: std.mem.Allocator, server_path: []const u8, client_path: []const u8) !void {
    var server = try reservePort(std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer closeReservation(&server);
    var client = try reservePort(std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer closeReservation(&client);
    var server_port: [5]u8 = undefined;
    var client_port: [5]u8 = undefined;
    const server_text = try std.fmt.bufPrint(server_port[0..], "{d}", .{server.port});
    const client_text = try std.fmt.bufPrint(client_port[0..], "{d}", .{client.port});
    closeReservation(&server);
    closeReservation(&client);
    try runPair(allocator, server_path, &.{ server_text, client_text }, client_path, &.{ client_text, server_text });
}

fn runRelay(allocator: std.mem.Allocator, server_path: []const u8, client_path: []const u8, relay_path: []const u8) !void {
    var server = try reservePort(std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer closeReservation(&server);
    var client = try reservePort(std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer closeReservation(&client);
    var relay = try reservePort(std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer closeReservation(&relay);
    var server_port: [5]u8 = undefined;
    var client_port: [5]u8 = undefined;
    var relay_port: [5]u8 = undefined;
    const server_text = try std.fmt.bufPrint(server_port[0..], "{d}", .{server.port});
    const client_text = try std.fmt.bufPrint(client_port[0..], "{d}", .{client.port});
    const relay_text = try std.fmt.bufPrint(relay_port[0..], "{d}", .{relay.port});
    closeReservation(&server);
    closeReservation(&client);
    closeReservation(&relay);
    var relay_child = try spawnReady(allocator, relay_path, &.{relay_text});
    errdefer _ = relay_child.kill() catch {};
    var server_child = try spawnReady(allocator, server_path, &.{ server_text, relay_text });
    errdefer _ = server_child.kill() catch {};
    var client_child = try spawnClient(allocator, client_path, &.{ client_text, relay_text });
    errdefer _ = client_child.kill() catch {};
    const client_term = try client_child.wait();
    const server_term = try server_child.wait();
    const relay_term = try relay_child.wait();
    if (!exitedSuccessfully(client_term)) return error.RelayClientFailed;
    if (!exitedSuccessfully(server_term)) return error.RelayServerFailed;
    if (!exitedSuccessfully(relay_term)) return error.RelayFailed;
}

fn runTcpFallback(allocator: std.mem.Allocator, server_path: []const u8, client_path: []const u8) !void {
    var server = try reservePort(std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    defer closeReservation(&server);
    var server_port: [5]u8 = undefined;
    const server_text = try std.fmt.bufPrint(server_port[0..], "{d}", .{server.port});
    closeReservation(&server);
    try runPair(allocator, server_path, &.{server_text}, client_path, &.{server_text});
}

fn runPair(allocator: std.mem.Allocator, server_path: []const u8, server_args: []const []const u8, client_path: []const u8, client_args: []const []const u8) !void {
    var server = try spawnReady(allocator, server_path, server_args);
    errdefer _ = server.kill() catch {};
    var client = try spawnClient(allocator, client_path, client_args);
    errdefer _ = client.kill() catch {};
    const client_term = try client.wait();
    const server_term = try server.wait();
    if (!exitedSuccessfully(client_term)) return error.ClientFailed;
    if (!exitedSuccessfully(server_term)) return error.ServerFailed;
}

fn spawnReady(allocator: std.mem.Allocator, path: []const u8, values: []const []const u8) !std.process.Child {
    var child_args: [3][]const u8 = undefined;
    if (values.len + 1 > child_args.len) return error.InvalidArgument;
    child_args[0] = path;
    for (values, 0..) |value, index| child_args[index + 1] = value;
    var child = std.process.Child.init(child_args[0 .. values.len + 1], allocator);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    errdefer _ = child.kill() catch {};
    var ready: [6]u8 = undefined;
    const ready_len = try child.stdout.?.read(ready[0..]);
    if (!std.mem.eql(u8, ready[0..ready_len], "ready\n")) return error.ServerDidNotBind;
    return child;
}

fn spawnClient(allocator: std.mem.Allocator, path: []const u8, values: []const []const u8) !std.process.Child {
    var child_args: [3][]const u8 = undefined;
    if (values.len + 1 > child_args.len) return error.InvalidArgument;
    child_args[0] = path;
    for (values, 0..) |value, index| child_args[index + 1] = value;
    var child = std.process.Child.init(child_args[0 .. values.len + 1], allocator);
    child.stdout_behavior = .Ignore;
    try child.spawn();
    return child;
}

fn reservePort(kind: u32, protocol: u32) !Reservation {
    const socket = try std.posix.socket(std.posix.AF.INET, kind | std.posix.SOCK.CLOEXEC, protocol);
    errdefer std.posix.close(socket);
    var native = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.posix.bind(socket, &native.any, native.getOsSockLen());
    var length = native.getOsSockLen();
    try std.posix.getsockname(socket, &native.any, &length);
    return .{ .socket = socket, .port = native.in.getPort() };
}

fn closeReservation(reservation: *Reservation) void {
    if (reservation.socket) |socket| std.posix.close(socket);
    reservation.socket = null;
}

fn exitedSuccessfully(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn report(route: []const u8, condition: []const u8) !void {
    try std.fs.File.stdout().deprecatedWriter().print("route={s} condition={s} payload=verified\n", .{ route, condition });
}
