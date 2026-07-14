const std = @import("std");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse return usage();
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) return usage();
    if (!std.mem.eql(u8, first, "--config")) return usage();
    const config_path = args.next() orelse return usage();
    var once = false;
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--once") or args.next() != null) return usage();
        once = true;
    }
    const runtime_config = try config.load(allocator, config_path);
    defer config.deinit(allocator, runtime_config);
    const address = try std.net.Address.parseIp(runtime_config.bind_address, runtime_config.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    std.debug.print("services: listening on {s}:{d}\n", .{ runtime_config.bind_address, server.listen_address.getPort() });
    if (once) return;
    while (true) {
        var connection = try server.accept();
        connection.stream.close();
    }
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build run -- --config <path> [--once]\n", .{});
    return error.InvalidArguments;
}
