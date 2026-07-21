const std = @import("std");

const Reservation = struct {
    socket: ?std.posix.socket_t,
    port: u16,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.InvalidArgument;
    var server = try reservePort();
    defer closeReservation(&server);
    var client = try reservePort();
    defer closeReservation(&client);
    var server_port: [5]u8 = undefined;
    var client_port: [5]u8 = undefined;
    const server_port_text = try std.fmt.bufPrint(server_port[0..], "{d}", .{server.port});
    const client_port_text = try std.fmt.bufPrint(client_port[0..], "{d}", .{client.port});
    closeReservation(&server);
    closeReservation(&client);
    var server_child = std.process.Child.init(&.{ args[1], server_port_text, client_port_text }, allocator);
    server_child.stdout_behavior = .Pipe;
    try server_child.spawn();
    errdefer _ = server_child.kill() catch {};
    var ready: [6]u8 = undefined;
    const ready_len = try server_child.stdout.?.read(ready[0..]);
    if (!std.mem.eql(u8, ready[0..ready_len], "ready\n")) return error.ServerDidNotBind;
    var client_child = std.process.Child.init(&.{ args[2], client_port_text, server_port_text }, allocator);
    try client_child.spawn();
    errdefer _ = client_child.kill() catch {};
    const client_term = try client_child.wait();
    const server_term = try server_child.wait();
    if (!exitedSuccessfully(client_term)) return error.ClientFailed;
    if (!exitedSuccessfully(server_term)) return error.ServerFailed;
}

fn reservePort() !Reservation {
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.UDP);
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
